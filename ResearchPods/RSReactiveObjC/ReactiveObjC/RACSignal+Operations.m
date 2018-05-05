//
//  RACSignal+Operations.m
//  ReactiveObjC
//
//  Created by Justin Spahr-Summers on 2012-09-06.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import "RACSignal+Operations.h"
#import "NSObject+RACDeallocating.h"
#import "NSObject+RACDescription.h"
#import "RACBlockTrampoline.h"
#import "RACCommand.h"
#import "RACCompoundDisposable.h"
#import "RACDisposable.h"
#import "RACEvent.h"
#import "RACGroupedSignal.h"
#import "RACMulticastConnection+Private.h"
#import "RACReplaySubject.h"
#import "RACScheduler.h"
#import "RACSerialDisposable.h"
#import "RACSignalSequence.h"
#import "RACStream+Private.h"
#import "RACSubject.h"
#import "RACSubscriber+Private.h"
#import "RACSubscriber.h"
#import "RACTuple.h"
#import "RACUnit.h"
#import <libkern/OSAtomic.h>
#import <objc/runtime.h>

NSString * const RACSignalErrorDomain = @"RACSignalErrorDomain";

const NSInteger RACSignalErrorTimedOut = 1;
const NSInteger RACSignalErrorNoMatchingCase = 2;

// Subscribes to the given signal with the given blocks.
//
// If the signal errors or completes, the corresponding block is invoked. If the
// disposable passed to the block is _not_ disposed, then the signal is
// subscribed to again.
static RACDisposable *subscribeForever (RACSignal *signal, void (^next)(id), void (^error)(NSError *, RACDisposable *), void (^completed)(RACDisposable *)) {
    // 先保存三个 block
	next = [next copy];
	error = [error copy];
	completed = [completed copy];

	RACCompoundDisposable *compoundDisposable = [RACCompoundDisposable compoundDisposable];

    // recursiveBlock 这个 block 接下来会被调用，这个 block 参数 recurse 也是一个 block
    // 最后会不断重复调用这个 block，也就是 forever
	RACSchedulerRecursiveBlock recursiveBlock = ^(void (^recurse)(void)) {
		RACCompoundDisposable *selfDisposable = [RACCompoundDisposable compoundDisposable];
		[compoundDisposable addDisposable:selfDisposable];

		__weak RACDisposable *weakSelfDisposable = selfDisposable;

        // 还是先对 signal 进行原始的订阅
		RACDisposable *subscriptionDisposable = [signal subscribeNext:next error:^(NSError *e) {
			@autoreleasepool {
                // 有错误就发出
				error(e, compoundDisposable);
				[compoundDisposable removeDisposable:weakSelfDisposable];
			}
            // recurse 有可能是被异步调用，有可能同步，同步就是一 subscribe 就立刻 send
			recurse();  // 保证再次递归调用
		} completed:^{
			@autoreleasepool {
                // 完成后回调
				completed(compoundDisposable);
				[compoundDisposable removeDisposable:weakSelfDisposable];
			}
            // recurse 有可能是被异步调用，有可能同步，同步就是一 subscribe 就立刻 send
			recurse();  // 保证再次递归调用
		}];

		[selfDisposable addDisposable:subscriptionDisposable];
	};

	// Subscribe once immediately, and then use recursive scheduling for any
	// further resubscriptions.
    // 立刻调用刚才的 recursiveBlock ，先订阅 singal，然后在其内部递归调用当前这个 block
	recursiveBlock(^{
        // recurse
		RACScheduler *recursiveScheduler = RACScheduler.currentScheduler ?: [RACScheduler scheduler];
        // 就是用一个可以递归的 schedule 再次调用 recursiveBlock
        // recursiveBlock 在 schedule 中的调用没有了参数，其实在 scheduleRecursiveBlock 内部会传入参数，参数是重试次数
		RACDisposable *schedulingDisposable = [recursiveScheduler scheduleRecursiveBlock:recursiveBlock];
		[compoundDisposable addDisposable:schedulingDisposable];
	});

	return compoundDisposable;
}

@implementation RACSignal (Operations)

- (RACSignal *)doNext:(void (^)(id x))block {
	NSCParameterAssert(block != NULL);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		return [self subscribeNext:^(id x) {
			block(x);
			[subscriber sendNext:x];
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
			[subscriber sendCompleted];
		}];
	}] setNameWithFormat:@"[%@] -doNext:", self.name];
}

- (RACSignal *)doError:(void (^)(NSError *error))block {
	NSCParameterAssert(block != NULL);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		return [self subscribeNext:^(id x) {
			[subscriber sendNext:x];
		} error:^(NSError *error) {
			block(error);
			[subscriber sendError:error];
		} completed:^{
			[subscriber sendCompleted];
		}];
	}] setNameWithFormat:@"[%@] -doError:", self.name];
}

- (RACSignal *)doCompleted:(void (^)(void))block {
	NSCParameterAssert(block != NULL);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		return [self subscribeNext:^(id x) {
			[subscriber sendNext:x];
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
			block();
			[subscriber sendCompleted];
		}];
	}] setNameWithFormat:@"[%@] -doCompleted:", self.name];
}

// 限流
- (RACSignal *)throttle:(NSTimeInterval)interval {
	return [[self throttle:interval valuesPassingTest:^(id _) {
		return YES;
	}] setNameWithFormat:@"[%@] -throttle: %f", self.name, (double)interval];
}

// 在原始信号发出每个 event 后的 time interval 内，如果没有新值，那么这个保存的值就发出来，不然就继续等
// 使用上就是限流，原始信号发出一个 value，只有在 interval 结束后，这段期间没新的 value，才会把这个 value 发出来
// 如果流量太大，可能会导致 next 一直不被掉
// predicate 表示是否需要将这个 value 加入到限流策略中
- (RACSignal *)throttle:(NSTimeInterval)interval valuesPassingTest:(BOOL (^)(id next))predicate {
	NSCParameterAssert(interval >= 0);
	NSCParameterAssert(predicate != nil);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACCompoundDisposable *compoundDisposable = [RACCompoundDisposable compoundDisposable];

		// We may never use this scheduler, but we need to set it up ahead of
		// time so that our scheduled blocks are run serially if we do.
		RACScheduler *scheduler = [RACScheduler scheduler];

		// Information about any currently-buffered `next` event.
		__block id nextValue = nil;
		__block BOOL hasNextValue = NO;
		RACSerialDisposable *nextDisposable = [[RACSerialDisposable alloc] init];

		void (^flushNext)(BOOL send) = ^(BOOL send) {
			@synchronized (compoundDisposable) {
                // 先清理上一个定时器
				[nextDisposable.disposable dispose];
                
                // 无下个值，直接返回
				if (!hasNextValue) return;
				if (send) [subscriber sendNext:nextValue];
                // 有下个值，需要清空
				nextValue = nil;
				hasNextValue = NO;
			}
		};

		RACDisposable *subscriptionDisposable = [self subscribeNext:^(id x) {
			RACScheduler *delayScheduler = RACScheduler.currentScheduler ?: scheduler;
            // predicate 表是是否豁免
			BOOL shouldThrottle = predicate(x);

			@synchronized (compoundDisposable) {
				flushNext(NO);  // 新的 value 到来，无需发送，清理之前的值
				if (!shouldThrottle) {
                    // 无视限流
					[subscriber sendNext:x];
					return;
				}
                // 需要被限流，保存这次值，并且在 timer 之后把这个值发出来，当然，这段时间不能有新值，不然 timer 被取消
				nextValue = x;
				hasNextValue = YES;
				nextDisposable.disposable = [delayScheduler afterDelay:interval schedule:^{
                    // 延迟 interval 后再次 flush ，这个期间的 value 都丢掉
					flushNext(YES);
				}];
			}
		} error:^(NSError *error) {
			[compoundDisposable dispose];
			[subscriber sendError:error];
		} completed:^{
			flushNext(YES);
			[subscriber sendCompleted];
		}];

		[compoundDisposable addDisposable:subscriptionDisposable];
		return compoundDisposable;
	}] setNameWithFormat:@"[%@] -throttle: %f valuesPassingTest:", self.name, (double)interval];
}

- (RACSignal *)delay:(NSTimeInterval)interval {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACCompoundDisposable *disposable = [RACCompoundDisposable compoundDisposable];

		// We may never use this scheduler, but we need to set it up ahead of
		// time so that our scheduled blocks are run serially if we do.
		RACScheduler *scheduler = [RACScheduler scheduler];

		void (^schedule)(dispatch_block_t) = ^(dispatch_block_t block) {
			RACScheduler *delayScheduler = RACScheduler.currentScheduler ?: scheduler;
			RACDisposable *schedulerDisposable = [delayScheduler afterDelay:interval schedule:block];
			[disposable addDisposable:schedulerDisposable];
		};

		RACDisposable *subscriptionDisposable = [self subscribeNext:^(id x) {
			schedule(^{
				[subscriber sendNext:x];
			});
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
			schedule(^{
				[subscriber sendCompleted];
			});
		}];

		[disposable addDisposable:subscriptionDisposable];
		return disposable;
	}] setNameWithFormat:@"[%@] -delay: %f", self.name, (double)interval];
}

// repeat 就是在 complte 时继续递归，error 时停止
- (RACSignal *)repeat {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		return subscribeForever(self,
			^(id x) {
				[subscriber sendNext:x];
			},
			^(NSError *error, RACDisposable *disposable) {
				[disposable dispose];
				[subscriber sendError:error];
			},
			^(RACDisposable *disposable) {
				// Resubscribe.
			});
	}] setNameWithFormat:@"[%@] -repeat", self.name];
}

- (RACSignal *)catch:(RACSignal * (^)(NSError *error))catchBlock {
	NSCParameterAssert(catchBlock != NULL);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACSerialDisposable *catchDisposable = [[RACSerialDisposable alloc] init];

		RACDisposable *subscriptionDisposable = [self subscribeNext:^(id x) {
			[subscriber sendNext:x];
		} error:^(NSError *error) {
			RACSignal *signal = catchBlock(error);
			NSCAssert(signal != nil, @"Expected non-nil signal from catch block on %@", self);
			catchDisposable.disposable = [signal subscribe:subscriber];
		} completed:^{
			[subscriber sendCompleted];
		}];

		return [RACDisposable disposableWithBlock:^{
			[catchDisposable dispose];
			[subscriptionDisposable dispose];
		}];
	}] setNameWithFormat:@"[%@] -catch:", self.name];
}

- (RACSignal *)catchTo:(RACSignal *)signal {
	return [[self catch:^(NSError *error) {
		return signal;
	}] setNameWithFormat:@"[%@] -catchTo: %@", self.name, signal];
}

+ (RACSignal *)try:(id (^)(NSError **errorPtr))tryBlock {
	NSCParameterAssert(tryBlock != NULL);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		NSError *error;
		id value = tryBlock(&error);
		RACSignal *signal = (value == nil ? [RACSignal error:error] : [RACSignal return:value]);
		return [signal subscribe:subscriber];
	}] setNameWithFormat:@"+try:"];
}

- (RACSignal *)try:(BOOL (^)(id value, NSError **errorPtr))tryBlock {
	NSCParameterAssert(tryBlock != NULL);

	return [[self flattenMap:^(id value) {
		NSError *error = nil;
		BOOL passed = tryBlock(value, &error);
		return (passed ? [RACSignal return:value] : [RACSignal error:error]);
	}] setNameWithFormat:@"[%@] -try:", self.name];
}

- (RACSignal *)tryMap:(id (^)(id value, NSError **errorPtr))mapBlock {
	NSCParameterAssert(mapBlock != NULL);

	return [[self flattenMap:^(id value) {
		NSError *error = nil;
		id mappedValue = mapBlock(value, &error);
		return (mappedValue == nil ? [RACSignal error:error] : [RACSignal return:mappedValue]);
	}] setNameWithFormat:@"[%@] -tryMap:", self.name];
}

- (RACSignal *)initially:(void (^)(void))block {
	NSCParameterAssert(block != NULL);

	return [[RACSignal defer:^{
		block();
		return self;
	}] setNameWithFormat:@"[%@] -initially:", self.name];
}

- (RACSignal *)finally:(void (^)(void))block {
	NSCParameterAssert(block != NULL);

	return [[[self
		doError:^(NSError *error) {
			block();
		}]
		doCompleted:^{
			block();
		}]
		setNameWithFormat:@"[%@] -finally:", self.name];
}

- (RACSignal *)bufferWithTime:(NSTimeInterval)interval onScheduler:(RACScheduler *)scheduler {
	NSCParameterAssert(scheduler != nil);
	NSCParameterAssert(scheduler != RACScheduler.immediateScheduler);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACSerialDisposable *timerDisposable = [[RACSerialDisposable alloc] init];
		NSMutableArray *values = [NSMutableArray array];

		void (^flushValues)() = ^{
			@synchronized (values) {
				[timerDisposable.disposable dispose];

				if (values.count == 0) return;

				RACTuple *tuple = [RACTuple tupleWithObjectsFromArray:values];
				[values removeAllObjects];
				[subscriber sendNext:tuple];
			}
		};

		RACDisposable *selfDisposable = [self subscribeNext:^(id x) {
			@synchronized (values) {
				if (values.count == 0) {
					timerDisposable.disposable = [scheduler afterDelay:interval schedule:flushValues];
				}

				[values addObject:x ?: RACTupleNil.tupleNil];
			}
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
			flushValues();
			[subscriber sendCompleted];
		}];

		return [RACDisposable disposableWithBlock:^{
			[selfDisposable dispose];
			[timerDisposable dispose];
		}];
	}] setNameWithFormat:@"[%@] -bufferWithTime: %f onScheduler: %@", self.name, (double)interval, scheduler];
}

// 利用合计方法，将所有的 values 封装到集合中
- (RACSignal *)collect {
	return [[self aggregateWithStartFactory:^{
		return [[NSMutableArray alloc] init];
	} reduce:^(NSMutableArray *collectedValues, id x) {
		[collectedValues addObject:(x ?: NSNull.null)];
		return collectedValues;
	}] setNameWithFormat:@"[%@] -collect", self.name];
}

- (RACSignal *)takeLast:(NSUInteger)count {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		NSMutableArray *valuesTaken = [NSMutableArray arrayWithCapacity:count];
		return [self subscribeNext:^(id x) {
			[valuesTaken addObject:x ? : RACTupleNil.tupleNil];

			while (valuesTaken.count > count) {
				[valuesTaken removeObjectAtIndex:0];
			}
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
			for (id value in valuesTaken) {
				[subscriber sendNext:value == RACTupleNil.tupleNil ? nil : value];
			}

			[subscriber sendCompleted];
		}];
	}] setNameWithFormat:@"[%@] -takeLast: %lu", self.name, (unsigned long)count];
}

- (RACSignal *)combineLatestWith:(RACSignal *)signal {
	NSCParameterAssert(signal != nil);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACCompoundDisposable *disposable = [RACCompoundDisposable compoundDisposable];

		__block id lastSelfValue = nil;
		__block BOOL selfCompleted = NO;

		__block id lastOtherValue = nil;
		__block BOOL otherCompleted = NO;

		void (^sendNext)(void) = ^{
			@synchronized (disposable) {
				if (lastSelfValue == nil || lastOtherValue == nil) return;
				[subscriber sendNext:RACTuplePack(lastSelfValue, lastOtherValue)];
			}
		};

		RACDisposable *selfDisposable = [self subscribeNext:^(id x) {
			@synchronized (disposable) {
				lastSelfValue = x ?: RACTupleNil.tupleNil;
				sendNext();
			}
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
			@synchronized (disposable) {
				selfCompleted = YES;
				if (otherCompleted) [subscriber sendCompleted];
			}
		}];

		[disposable addDisposable:selfDisposable];

		RACDisposable *otherDisposable = [signal subscribeNext:^(id x) {
			@synchronized (disposable) {
				lastOtherValue = x ?: RACTupleNil.tupleNil;
				sendNext();
			}
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
			@synchronized (disposable) {
				otherCompleted = YES;
				if (selfCompleted) [subscriber sendCompleted];
			}
		}];

		[disposable addDisposable:otherDisposable];

		return disposable;
	}] setNameWithFormat:@"[%@] -combineLatestWith: %@", self.name, signal];
}

+ (RACSignal *)combineLatest:(id<NSFastEnumeration>)signals {
	return [[self join:signals block:^(RACSignal *left, RACSignal *right) {
		return [left combineLatestWith:right];
	}] setNameWithFormat:@"+combineLatest: %@", signals];
}

+ (RACSignal *)combineLatest:(id<NSFastEnumeration>)signals reduce:(RACGenericReduceBlock)reduceBlock {
	NSCParameterAssert(reduceBlock != nil);

	RACSignal *result = [self combineLatest:signals];

	// Although we assert this condition above, older versions of this method
	// supported this argument being nil. Avoid crashing Release builds of
	// apps that depended on that.
	if (reduceBlock != nil) result = [result reduceEach:reduceBlock];

	return [result setNameWithFormat:@"+combineLatest: %@ reduce:", signals];
}

- (RACSignal *)merge:(RACSignal *)signal {
	return [[RACSignal
		merge:@[ self, signal ]]
		setNameWithFormat:@"[%@] -merge: %@", self.name, signal];
}

+ (RACSignal *)merge:(id<NSFastEnumeration>)signals {
	NSMutableArray *copiedSignals = [[NSMutableArray alloc] init];
	for (RACSignal *signal in signals) {
		[copiedSignals addObject:signal];
	}

	return [[[RACSignal
		createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
			for (RACSignal *signal in copiedSignals) {
				[subscriber sendNext:signal];
			}

			[subscriber sendCompleted];
			return nil;
		}]
		flatten]
		setNameWithFormat:@"+merge: %@", copiedSignals];
}

- (RACSignal *)flatten:(NSUInteger)maxConcurrent {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACCompoundDisposable *compoundDisposable = [[RACCompoundDisposable alloc] init];

		// Contains disposables for the currently active subscriptions.
		//
		// This should only be used while synchronized on `subscriber`.
		NSMutableArray *activeDisposables = [[NSMutableArray alloc] initWithCapacity:maxConcurrent];

		// Whether the signal-of-signals has completed yet.
		//
		// This should only be used while synchronized on `subscriber`.
		__block BOOL selfCompleted = NO;

		// Subscribes to the given signal.
		__block void (^subscribeToSignal)(RACSignal *);

		// Weak reference to the above, to avoid a leak.
		__weak __block void (^recur)(RACSignal *);

		// Sends completed to the subscriber if all signals are finished.
		//
		// This should only be used while synchronized on `subscriber`.
		void (^completeIfAllowed)(void) = ^{
			if (selfCompleted && activeDisposables.count == 0) {
				[subscriber sendCompleted];
			}
		};

		// The signals waiting to be started.
		//
		// This array should only be used while synchronized on `subscriber`.
		NSMutableArray *queuedSignals = [NSMutableArray array];

		recur = subscribeToSignal = ^(RACSignal *signal) {
			RACSerialDisposable *serialDisposable = [[RACSerialDisposable alloc] init];

			@synchronized (subscriber) {
				[compoundDisposable addDisposable:serialDisposable];
				[activeDisposables addObject:serialDisposable];
			}

			serialDisposable.disposable = [signal subscribeNext:^(id x) {
				[subscriber sendNext:x];
			} error:^(NSError *error) {
				[subscriber sendError:error];
			} completed:^{
				__strong void (^subscribeToSignal)(RACSignal *) = recur;
				RACSignal *nextSignal;

				@synchronized (subscriber) {
					[compoundDisposable removeDisposable:serialDisposable];
					[activeDisposables removeObjectIdenticalTo:serialDisposable];

					if (queuedSignals.count == 0) {
						completeIfAllowed();
						return;
					}

					nextSignal = queuedSignals[0];
					[queuedSignals removeObjectAtIndex:0];
				}

				subscribeToSignal(nextSignal);
			}];
		};

		[compoundDisposable addDisposable:[self subscribeNext:^(RACSignal *signal) {
			if (signal == nil) return;

			NSCAssert([signal isKindOfClass:RACSignal.class], @"Expected a RACSignal, got %@", signal);

			@synchronized (subscriber) {
				if (maxConcurrent > 0 && activeDisposables.count >= maxConcurrent) {
					[queuedSignals addObject:signal];

					// If we need to wait, skip subscribing to this
					// signal.
					return;
				}
			}

			subscribeToSignal(signal);
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
			@synchronized (subscriber) {
				selfCompleted = YES;
				completeIfAllowed();
			}
		}]];

		[compoundDisposable addDisposable:[RACDisposable disposableWithBlock:^{
			// A strong reference is held to `subscribeToSignal` until we're
			// done, preventing it from deallocating early.
			subscribeToSignal = nil;
		}]];

		return compoundDisposable;
	}] setNameWithFormat:@"[%@] -flatten: %lu", self.name, (unsigned long)maxConcurrent];
}

- (RACSignal *)then:(RACSignal * (^)(void))block {
	NSCParameterAssert(block != nil);

	return [[[self
		ignoreValues]
		concat:[RACSignal defer:block]]
		setNameWithFormat:@"[%@] -then:", self.name];
}

//
- (RACSignal *)concat {
	return [[self flatten:1] setNameWithFormat:@"[%@] -concat", self.name];
}

// 合计
- (RACSignal *)aggregateWithStartFactory:(id (^)(void))startFactory reduce:(id (^)(id running, id next))reduceBlock {
	NSCParameterAssert(startFactory != NULL);
	NSCParameterAssert(reduceBlock != NULL);

	return [[RACSignal defer:^{
		return [self aggregateWithStart:startFactory() reduce:reduceBlock];
	}] setNameWithFormat:@"[%@] -aggregateWithStartFactory:reduce:", self.name];
}

// 合计
- (RACSignal *)aggregateWithStart:(id)start reduce:(id (^)(id running, id next))reduceBlock {
	return [[self
		aggregateWithStart:start
		reduceWithIndex:^(id running, id next, NSUInteger index) {
			return reduceBlock(running, next);
		}]
		setNameWithFormat:@"[%@] -aggregateWithStart: %@ reduce:", self.name, RACDescription(start)];
}

// 得到  last 合计
- (RACSignal *)aggregateWithStart:(id)start reduceWithIndex:(id (^)(id, id, NSUInteger))reduceBlock {
	return [[[[self
		scanWithStart:start reduceWithIndex:reduceBlock]
		startWith:start]
		takeLast:1]
		setNameWithFormat:@"[%@] -aggregateWithStart: %@ reduceWithIndex:", self.name, RACDescription(start)];
}

- (RACDisposable *)setKeyPath:(NSString *)keyPath onObject:(NSObject *)object {
	return [self setKeyPath:keyPath onObject:object nilValue:nil];
}

- (RACDisposable *)setKeyPath:(NSString *)keyPath onObject:(NSObject *)object nilValue:(id)nilValue {
	NSCParameterAssert(keyPath != nil);
	NSCParameterAssert(object != nil);

	keyPath = [keyPath copy];

	RACCompoundDisposable *disposable = [RACCompoundDisposable compoundDisposable];

	// Purposely not retaining 'object', since we want to tear down the binding
	// when it deallocates normally.
	__block void * volatile objectPtr = (__bridge void *)object;

	RACDisposable *subscriptionDisposable = [self subscribeNext:^(id x) {
		// Possibly spec, possibly compiler bug, but this __bridge cast does not
		// result in a retain here, effectively an invisible __unsafe_unretained
		// qualifier. Using objc_precise_lifetime gives the __strong reference
		// desired. The explicit use of __strong is strictly defensive.
		__strong NSObject *object __attribute__((objc_precise_lifetime)) = (__bridge __strong id)objectPtr;
		[object setValue:x ?: nilValue forKeyPath:keyPath];
	} error:^(NSError *error) {
		__strong NSObject *object __attribute__((objc_precise_lifetime)) = (__bridge __strong id)objectPtr;

		NSCAssert(NO, @"Received error from %@ in binding for key path \"%@\" on %@: %@", self, keyPath, object, error);

		// Log the error if we're running with assertions disabled.
		NSLog(@"Received error from %@ in binding for key path \"%@\" on %@: %@", self, keyPath, object, error);

		[disposable dispose];
	} completed:^{
		[disposable dispose];
	}];

	[disposable addDisposable:subscriptionDisposable];

	#if DEBUG
	static void *bindingsKey = &bindingsKey;
	NSMutableDictionary *bindings;

	@synchronized (object) {
		bindings = objc_getAssociatedObject(object, bindingsKey);
		if (bindings == nil) {
			bindings = [NSMutableDictionary dictionary];
			objc_setAssociatedObject(object, bindingsKey, bindings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
	}

	@synchronized (bindings) {
		NSCAssert(bindings[keyPath] == nil, @"Signal %@ is already bound to key path \"%@\" on object %@, adding signal %@ is undefined behavior", [bindings[keyPath] nonretainedObjectValue], keyPath, object, self);

		bindings[keyPath] = [NSValue valueWithNonretainedObject:self];
	}
	#endif

	RACDisposable *clearPointerDisposable = [RACDisposable disposableWithBlock:^{
		#if DEBUG
		@synchronized (bindings) {
			[bindings removeObjectForKey:keyPath];
		}
		#endif

		while (YES) {
			void *ptr = objectPtr;
			if (OSAtomicCompareAndSwapPtrBarrier(ptr, NULL, &objectPtr)) {
				break;
			}
		}
	}];

	[disposable addDisposable:clearPointerDisposable];

	[object.rac_deallocDisposable addDisposable:disposable];

	RACCompoundDisposable *objectDisposable = object.rac_deallocDisposable;
	return [RACDisposable disposableWithBlock:^{
		[objectDisposable removeDisposable:disposable];
		[disposable dispose];
	}];
}

+ (RACSignal *)interval:(NSTimeInterval)interval onScheduler:(RACScheduler *)scheduler {
	return [[RACSignal interval:interval onScheduler:scheduler withLeeway:0.0] setNameWithFormat:@"+interval: %f onScheduler: %@", (double)interval, scheduler];
}

+ (RACSignal *)interval:(NSTimeInterval)interval onScheduler:(RACScheduler *)scheduler withLeeway:(NSTimeInterval)leeway {
	NSCParameterAssert(scheduler != nil);
	NSCParameterAssert(scheduler != RACScheduler.immediateScheduler);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		return [scheduler after:[NSDate dateWithTimeIntervalSinceNow:interval] repeatingEvery:interval withLeeway:leeway schedule:^{
			[subscriber sendNext:[NSDate date]];
		}];
	}] setNameWithFormat:@"+interval: %f onScheduler: %@ withLeeway: %f", (double)interval, scheduler, (double)leeway];
}

- (RACSignal *)takeUntil:(RACSignal *)signalTrigger {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACCompoundDisposable *disposable = [RACCompoundDisposable compoundDisposable];
		void (^triggerCompletion)(void) = ^{
			[disposable dispose];
			[subscriber sendCompleted];
		};

		RACDisposable *triggerDisposable = [signalTrigger subscribeNext:^(id _) {
			triggerCompletion();
		} completed:^{
			triggerCompletion();
		}];

		[disposable addDisposable:triggerDisposable];

		if (!disposable.disposed) {
			RACDisposable *selfDisposable = [self subscribeNext:^(id x) {
				[subscriber sendNext:x];
			} error:^(NSError *error) {
				[subscriber sendError:error];
			} completed:^{
				[disposable dispose];
				[subscriber sendCompleted];
			}];

			[disposable addDisposable:selfDisposable];
		}

		return disposable;
	}] setNameWithFormat:@"[%@] -takeUntil: %@", self.name, signalTrigger];
}

- (RACSignal *)takeUntilReplacement:(RACSignal *)replacement {
	return [RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACSerialDisposable *selfDisposable = [[RACSerialDisposable alloc] init];

		RACDisposable *replacementDisposable = [replacement subscribeNext:^(id x) {
			[selfDisposable dispose];
			[subscriber sendNext:x];
		} error:^(NSError *error) {
			[selfDisposable dispose];
			[subscriber sendError:error];
		} completed:^{
			[selfDisposable dispose];
			[subscriber sendCompleted];
		}];

		if (!selfDisposable.disposed) {
			selfDisposable.disposable = [[self
				concat:[RACSignal never]]
				subscribe:subscriber];
		}

		return [RACDisposable disposableWithBlock:^{
			[selfDisposable dispose];
			[replacementDisposable dispose];
		}];
	}];
}

- (RACSignal *)switchToLatest {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACMulticastConnection *connection = [self publish];

		RACDisposable *subscriptionDisposable = [[connection.signal
			flattenMap:^(RACSignal *x) {
				NSCAssert(x == nil || [x isKindOfClass:RACSignal.class], @"-switchToLatest requires that the source signal (%@) send signals. Instead we got: %@", self, x);

				// -concat:[RACSignal never] prevents completion of the receiver from
				// prematurely terminating the inner signal.
				return [x takeUntil:[connection.signal concat:[RACSignal never]]];
			}]
			subscribe:subscriber];

		RACDisposable *connectionDisposable = [connection connect];
		return [RACDisposable disposableWithBlock:^{
			[subscriptionDisposable dispose];
			[connectionDisposable dispose];
		}];
	}] setNameWithFormat:@"[%@] -switchToLatest", self.name];
}

+ (RACSignal *)switch:(RACSignal *)signal cases:(NSDictionary *)cases default:(RACSignal *)defaultSignal {
	NSCParameterAssert(signal != nil);
	NSCParameterAssert(cases != nil);

	for (id key in cases) {
		id value __attribute__((unused)) = cases[key];
		NSCAssert([value isKindOfClass:RACSignal.class], @"Expected all cases to be RACSignals, %@ isn't", value);
	}

	NSDictionary *copy = [cases copy];

	return [[[signal
		map:^(id key) {
			if (key == nil) key = RACTupleNil.tupleNil;

			RACSignal *signal = copy[key] ?: defaultSignal;
			if (signal == nil) {
				NSString *description = [NSString stringWithFormat:NSLocalizedString(@"No matching signal found for value %@", @""), key];
				return [RACSignal error:[NSError errorWithDomain:RACSignalErrorDomain code:RACSignalErrorNoMatchingCase userInfo:@{ NSLocalizedDescriptionKey: description }]];
			}

			return signal;
		}]
		switchToLatest]
		setNameWithFormat:@"+switch: %@ cases: %@ default: %@", signal, cases, defaultSignal];
}

+ (RACSignal *)if:(RACSignal *)boolSignal then:(RACSignal *)trueSignal else:(RACSignal *)falseSignal {
	NSCParameterAssert(boolSignal != nil);
	NSCParameterAssert(trueSignal != nil);
	NSCParameterAssert(falseSignal != nil);

	return [[[boolSignal
		map:^(NSNumber *value) {
			NSCAssert([value isKindOfClass:NSNumber.class], @"Expected %@ to send BOOLs, not %@", boolSignal, value);

			return (value.boolValue ? trueSignal : falseSignal);
		}]
		switchToLatest]
		setNameWithFormat:@"+if: %@ then: %@ else: %@", boolSignal, trueSignal, falseSignal];
}

- (id)first {
	return [self firstOrDefault:nil];
}

- (id)firstOrDefault:(id)defaultValue {
	return [self firstOrDefault:defaultValue success:NULL error:NULL];
}

- (id)firstOrDefault:(id)defaultValue success:(BOOL *)success error:(NSError **)error {
	NSCondition *condition = [[NSCondition alloc] init];
	condition.name = [NSString stringWithFormat:@"[%@] -firstOrDefault: %@ success:error:", self.name, defaultValue];

	__block id value = defaultValue;
	__block BOOL done = NO;

	// Ensures that we don't pass values across thread boundaries by reference.
	__block NSError *localError;
	__block BOOL localSuccess;

	[[self take:1] subscribeNext:^(id x) {
		[condition lock];

		value = x;
		localSuccess = YES;

		done = YES;
		[condition broadcast];
		[condition unlock];
	} error:^(NSError *e) {
		[condition lock];

		if (!done) {
			localSuccess = NO;
			localError = e;

			done = YES;
			[condition broadcast];
		}

		[condition unlock];
	} completed:^{
		[condition lock];

		localSuccess = YES;

		done = YES;
		[condition broadcast];
		[condition unlock];
	}];

	[condition lock];
	while (!done) {
		[condition wait];
	}

	if (success != NULL) *success = localSuccess;
	if (error != NULL) *error = localError;

	[condition unlock];
	return value;
}

- (BOOL)waitUntilCompleted:(NSError **)error {
	BOOL success = NO;

	[[[self
		ignoreValues]
		setNameWithFormat:@"[%@] -waitUntilCompleted:", self.name]
		firstOrDefault:nil success:&success error:error];

	return success;
}

+ (RACSignal *)defer:(RACSignal<id> * (^)(void))block {
	NSCParameterAssert(block != NULL);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		return [block() subscribe:subscriber];
	}] setNameWithFormat:@"+defer:"];
}

- (NSArray *)toArray {
	return [[[self collect] first] copy];
}

- (RACSequence *)sequence {
	return [[RACSignalSequence sequenceWithSignal:self] setNameWithFormat:@"[%@] -sequence", self.name];
}

- (RACMulticastConnection *)publish {
	RACSubject *subject = [[RACSubject subject] setNameWithFormat:@"[%@] -publish", self.name];
	RACMulticastConnection *connection = [self multicast:subject];
	return connection;
}

- (RACMulticastConnection *)multicast:(RACSubject *)subject {
	[subject setNameWithFormat:@"[%@] -multicast: %@", self.name, subject.name];
	RACMulticastConnection *connection = [[RACMulticastConnection alloc] initWithSourceSignal:self subject:subject];
	return connection;
}

- (RACSignal *)replay {
	RACReplaySubject *subject = [[RACReplaySubject subject] setNameWithFormat:@"[%@] -replay", self.name];

	RACMulticastConnection *connection = [self multicast:subject];
	[connection connect];

	return connection.signal;
}

- (RACSignal *)replayLast {
	RACReplaySubject *subject = [[RACReplaySubject replaySubjectWithCapacity:1] setNameWithFormat:@"[%@] -replayLast", self.name];

	RACMulticastConnection *connection = [self multicast:subject];
	[connection connect];

	return connection.signal;
}

//
- (RACSignal *)replayLazily {
	RACMulticastConnection *connection = [self multicast:[RACReplaySubject subject]];
	return [[RACSignal
		defer:^{
			[connection connect];
			return connection.signal;
		}]
		setNameWithFormat:@"[%@] -replayLazily", self.name];
}

// 其实就是 timeout 后，就在 scheduler 上 dispose 并发送 error
- (RACSignal *)timeout:(NSTimeInterval)interval onScheduler:(RACScheduler *)scheduler {
	NSCParameterAssert(scheduler != nil);
	NSCParameterAssert(scheduler != RACScheduler.immediateScheduler);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACCompoundDisposable *disposable = [RACCompoundDisposable compoundDisposable];

		RACDisposable *timeoutDisposable = [scheduler afterDelay:interval schedule:^{
			[disposable dispose];
			[subscriber sendError:[NSError errorWithDomain:RACSignalErrorDomain code:RACSignalErrorTimedOut userInfo:nil]];
		}];

		[disposable addDisposable:timeoutDisposable];

		RACDisposable *subscriptionDisposable = [self subscribeNext:^(id x) {
			[subscriber sendNext:x];
		} error:^(NSError *error) {
			[disposable dispose];
			[subscriber sendError:error];
		} completed:^{
			[disposable dispose];
			[subscriber sendCompleted];
		}];

		[disposable addDisposable:subscriptionDisposable];
		return disposable;
	}] setNameWithFormat:@"[%@] -timeout: %f onScheduler: %@", self.name, (double)interval, scheduler];
}

// 分发到 scheduler 上
- (RACSignal *)deliverOn:(RACScheduler *)scheduler {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		return [self subscribeNext:^(id x) {
			[scheduler schedule:^{
				[subscriber sendNext:x];
			}];
		} error:^(NSError *error) {
			[scheduler schedule:^{
				[subscriber sendError:error];
			}];
		} completed:^{
			[scheduler schedule:^{
				[subscriber sendCompleted];
			}];
		}];
	}] setNameWithFormat:@"[%@] -deliverOn: %@", self.name, scheduler];
}

// 在 scheduler 上订阅
- (RACSignal *)subscribeOn:(RACScheduler *)scheduler {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACCompoundDisposable *disposable = [RACCompoundDisposable compoundDisposable];

		RACDisposable *schedulingDisposable = [scheduler schedule:^{
			RACDisposable *subscriptionDisposable = [self subscribe:subscriber];

			[disposable addDisposable:subscriptionDisposable];
		}];

		[disposable addDisposable:schedulingDisposable];
		return disposable;
	}] setNameWithFormat:@"[%@] -subscribeOn: %@", self.name, scheduler];
}

// 保证分发在主线程上
- (RACSignal *)deliverOnMainThread {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		__block volatile int32_t queueLength = 0;
		
		void (^performOnMainThread)(dispatch_block_t) = ^(dispatch_block_t block) {
			int32_t queued = OSAtomicIncrement32(&queueLength);
			if (NSThread.isMainThread && queued == 1) {
				block();
				OSAtomicDecrement32(&queueLength);
			} else {
				dispatch_async(dispatch_get_main_queue(), ^{
					block();
					OSAtomicDecrement32(&queueLength);
				});
			}
		};

		return [self subscribeNext:^(id x) {
			performOnMainThread(^{
				[subscriber sendNext:x];
			});
		} error:^(NSError *error) {
			performOnMainThread(^{
				[subscriber sendError:error];
			});
		} completed:^{
			performOnMainThread(^{
				[subscriber sendCompleted];
			});
		}];
	}] setNameWithFormat:@"[%@] -deliverOnMainThread", self.name];
}

// 信号分组，根据 keyBlock 把 value 分成多个组，return signal 发出的事件是一个信号，这个信号是一个组一个信号
- (RACSignal *)groupBy:(id<NSCopying> (^)(id object))keyBlock transform:(id (^)(id object))transformBlock {
	NSCParameterAssert(keyBlock != NULL);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		NSMutableDictionary *groups = [NSMutableDictionary dictionary];
		NSMutableArray *orderedGroups = [NSMutableArray array];

		return [self subscribeNext:^(id x) {
            // 订阅自己的 values，得到 key
			id<NSCopying> key = keyBlock(x);
			RACGroupedSignal *groupSubject = nil;
			@synchronized(groups) {
                // 获取 group 中这个 key 对应的 groupSubject
				groupSubject = groups[key];
				if (groupSubject == nil) {
                    // 如果没有，就创建一个新的 groupSubject，其实就是一个热信号
					groupSubject = [RACGroupedSignal signalWithKey:key];
					groups[key] = groupSubject;
					[orderedGroups addObject:groupSubject];
                    // 发现新的 groupSubject 都需要传递出去
					[subscriber sendNext:groupSubject];
				}
			}
            // 让热信号发出事件，需要 transform 的就先 transform，不然就直接发出去
			[groupSubject sendNext:transformBlock != NULL ? transformBlock(x) : x];
		} error:^(NSError *error) {
			[subscriber sendError:error];
            // 如果 self 原始信号出错了，那么给所有的 group 热信号发送 error
			[orderedGroups makeObjectsPerformSelector:@selector(sendError:) withObject:error];
		} completed:^{
			[subscriber sendCompleted];
            // 同样，完成就大家都完成
			[orderedGroups makeObjectsPerformSelector:@selector(sendCompleted)];
		}];
	}] setNameWithFormat:@"[%@] -groupBy:transform:", self.name];
}

// 不需要 transform 的 group
- (RACSignal *)groupBy:(id<NSCopying> (^)(id object))keyBlock {
	return [[self groupBy:keyBlock transform:nil] setNameWithFormat:@"[%@] -groupBy:", self.name];
}

// 这个 any 因为永远满足，所以只要有信号发出，不管是 complete、error、next，都返回 YES
- (RACSignal *)any {
	return [[self any:^(id x) {
		return YES;
	}] setNameWithFormat:@"[%@] -any", self.name];
}

// Any，找到第一个满足 block 条件的 value，并且返回 YES，如果没找到就返回 NO
- (RACSignal *)any:(BOOL (^)(id object))predicateBlock {
	NSCParameterAssert(predicateBlock != NULL);

    // 具像化转为 event 后 bind
	return [[[self materialize] bind:^{
		return ^(RACEvent *event, BOOL *stop) {
			if (event.finished) {
				*stop = YES;
				return [RACSignal return:@NO];
			}

			if (predicateBlock(event.value)) {
				*stop = YES;
				return [RACSignal return:@YES];
			}

			return [RACSignal empty];
		};
	}] setNameWithFormat:@"[%@] -any:", self.name];
}

// 要求所有的 value 都满足 predicateBlock，当 completed 后就返回 YES
// 如果中间有一个 Error 事件或者 predicateBlock 不满足，就 return NO
// 可以用来判断整个原信号发送过程中是否有错误事件RACEventTypeError，或者是否存在predicateBlock为NO的情况
- (RACSignal *)all:(BOOL (^)(id object))predicateBlock {
	NSCParameterAssert(predicateBlock != NULL);

	return [[[self materialize] bind:^{
		return ^(RACEvent *event, BOOL *stop) {
			if (event.eventType == RACEventTypeCompleted) {
				*stop = YES;
				return [RACSignal return:@YES];
			}

			if (event.eventType == RACEventTypeError || !predicateBlock(event.value)) {
				*stop = YES;
				return [RACSignal return:@NO];
			}

			return [RACSignal empty];
		};
	}] setNameWithFormat:@"[%@] -all:", self.name];
}

// retry 就是在 error 发生时，前面的 count 次数里，不 dispose，不 sendError，从而继续下去
// 但是只有发生 error 时才 retry
- (RACSignal *)retry:(NSInteger)retryCount {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		__block NSInteger currentRetryCount = 0;
		return subscribeForever(self,
			^(id x) {
				[subscriber sendNext:x];
			},
			^(NSError *error, RACDisposable *disposable) {
				if (retryCount == 0 || currentRetryCount < retryCount) {
					// Resubscribe.
					currentRetryCount++;
					return;
				}

				[disposable dispose];
				[subscriber sendError:error];
			},
			^(RACDisposable *disposable) {
                // repeat 这里什么都没有，因为是需要不断循环，但是 retry 这里不一样，当这次递归操作 completed 后，就不再执行了
				[disposable dispose];
				[subscriber sendCompleted];
			});
	}] setNameWithFormat:@"[%@] -retry: %lu", self.name, (unsigned long)retryCount];
}

// retry 无数次，但是只有发生 error 时才 retry
- (RACSignal *)retry {
	return [[self retry:0] setNameWithFormat:@"[%@] -retry", self.name];
}

// 取样器，当 sampler 发生事件时，就从 self signal 中拿最后一个值
// 最后一个值是可以重复的
- (RACSignal *)sample:(RACSignal *)sampler {
	NSCParameterAssert(sampler != nil);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		NSLock *lock = [[NSLock alloc] init];
		__block id lastValue;
		__block BOOL hasValue = NO;

		RACSerialDisposable *samplerDisposable = [[RACSerialDisposable alloc] init];
		RACDisposable *sourceDisposable = [self subscribeNext:^(id x) {
			[lock lock];    // source signal 用来保存 lastValue
			hasValue = YES;
			lastValue = x;
			[lock unlock];
		} error:^(NSError *error) {
			[samplerDisposable dispose];
			[subscriber sendError:error];
		} completed:^{
			[samplerDisposable dispose];
			[subscriber sendCompleted];
		}];

		samplerDisposable.disposable = [sampler subscribeNext:^(id _) {
			BOOL shouldSend = NO;
			id value;
			[lock lock];
			shouldSend = hasValue;  // 获取 source 的 value，当 sampler 有 event 时
			value = lastValue;
			[lock unlock];

			if (shouldSend) {
				[subscriber sendNext:value];    // 取样器发出取样
			}
		} error:^(NSError *error) {
			[sourceDisposable dispose];
			[subscriber sendError:error];
		} completed:^{
			[sourceDisposable dispose];
			[subscriber sendCompleted];
		}];

		return [RACDisposable disposableWithBlock:^{
			[samplerDisposable dispose];
			[sourceDisposable dispose];
		}];
	}] setNameWithFormat:@"[%@] -sample: %@", self.name, sampler];
}

- (RACSignal *)ignoreValues {
	return [[self filter:^(id _) {
		return NO;
	}] setNameWithFormat:@"[%@] -ignoreValues", self.name];
}

// 订阅自己，将 value、error、complte 都包装为 event
- (RACSignal *)materialize {
    // 还是创建新的 signal
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
        // 订阅自己，将 value、error、complte 都包装为 event
        // 这样就保证 materialize 后只有 onNext 事件
		return [self subscribeNext:^(id x) {
			[subscriber sendNext:[RACEvent eventWithValue:x]];
		} error:^(NSError *error) {
			[subscriber sendNext:[RACEvent eventWithError:error]];
			[subscriber sendCompleted];
		} completed:^{
			[subscriber sendNext:RACEvent.completedEvent];
			[subscriber sendCompleted];
		}];
	}] setNameWithFormat:@"[%@] -materialize", self.name];
}

// dematerialize 就是 materialize 的逆向
- (RACSignal *)dematerialize {
	return [[self bind:^{
		return ^(RACEvent *event, BOOL *stop) {
            // 仍然是 bind
			switch (event.eventType) {
                    // ，对 complete 事件转为 空
				case RACEventTypeCompleted:
					*stop = YES;
					return [RACSignal empty];
                    // error 还原，并停止
				case RACEventTypeError:
					*stop = YES;
					return [RACSignal error:event.error];
                    // next 直接还原为 value 就好了
				case RACEventTypeNext:
					return [RACSignal return:event.value];
			}
		};
	}] setNameWithFormat:@"[%@] -dematerialize", self.name];
}

// not 其实就是对所有的 BOOL 取反，不过要求必须是 NSNumber
- (RACSignal *)not {
	return [[self map:^(NSNumber *value) {
		NSCAssert([value isKindOfClass:NSNumber.class], @"-not must only be used on a signal of NSNumbers. Instead, got: %@", value);

		return @(!value.boolValue);
	}] setNameWithFormat:@"[%@] -not", self.name];
}

// and 要求都是 tuple ，然后对 tuple 内部进行 and 操作
- (RACSignal *)and {
	return [[self map:^(RACTuple *tuple) {
		NSCAssert([tuple isKindOfClass:RACTuple.class], @"-and must only be used on a signal of RACTuples of NSNumbers. Instead, received: %@", tuple);
		NSCAssert(tuple.count > 0, @"-and must only be used on a signal of RACTuples of NSNumbers, with at least 1 value in the tuple");

		return @([tuple.rac_sequence all:^(NSNumber *number) {
			NSCAssert([number isKindOfClass:NSNumber.class], @"-and must only be used on a signal of RACTuples of NSNumbers. Instead, tuple contains a non-NSNumber value: %@", tuple);

			return number.boolValue;
		}]);
	}] setNameWithFormat:@"[%@] -and", self.name];
}

// or 与 and 相反，只要 tuple 中的一个是 YES 就行
- (RACSignal *)or {
	return [[self map:^(RACTuple *tuple) {
		NSCAssert([tuple isKindOfClass:RACTuple.class], @"-or must only be used on a signal of RACTuples of NSNumbers. Instead, received: %@", tuple);
		NSCAssert(tuple.count > 0, @"-or must only be used on a signal of RACTuples of NSNumbers, with at least 1 value in the tuple");

		return @([tuple.rac_sequence any:^(NSNumber *number) {
			NSCAssert([number isKindOfClass:NSNumber.class], @"-or must only be used on a signal of RACTuples of NSNumbers. Instead, tuple contains a non-NSNumber value: %@", tuple);

			return number.boolValue;
		}]);
	}] setNameWithFormat:@"[%@] -or", self.name];
}
// reduce apply 其实还是 Map tuple ，不过这次是自带了 block，tuple 的第一个参数为 block，tuple 后面的参数个数还要与第一个 block 一致
- (RACSignal *)reduceApply {
	return [[self map:^(RACTuple *tuple) {
		NSCAssert([tuple isKindOfClass:RACTuple.class], @"-reduceApply must only be used on a signal of RACTuples. Instead, received: %@", tuple);
		NSCAssert(tuple.count > 1, @"-reduceApply must only be used on a signal of RACTuples, with at least a block in tuple[0] and its first argument in tuple[1]");

		// We can't use -array, because we need to preserve RACTupleNil
		NSMutableArray *tupleArray = [NSMutableArray arrayWithCapacity:tuple.count];
		for (id val in tuple) {
			[tupleArray addObject:val];
		}
		RACTuple *arguments = [RACTuple tupleWithObjectsFromArray:[tupleArray subarrayWithRange:NSMakeRange(1, tupleArray.count - 1)]];

		return [RACBlockTrampoline invokeBlock:tuple[0] withArguments:arguments];
	}] setNameWithFormat:@"[%@] -reduceApply", self.name];
}

@end
