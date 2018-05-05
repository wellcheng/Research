//
//  RACScheduler.m
//  ReactiveObjC
//
//  Created by Josh Abernathy on 4/16/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import "RACScheduler.h"
#import "RACCompoundDisposable.h"
#import "RACDisposable.h"
#import "RACImmediateScheduler.h"
#import "RACScheduler+Private.h"
#import "RACSubscriptionScheduler.h"
#import "RACTargetQueueScheduler.h"

// The key for the thread-specific current scheduler.
NSString * const RACSchedulerCurrentSchedulerKey = @"RACSchedulerCurrentSchedulerKey";

@interface RACScheduler ()
@property (nonatomic, readonly, copy) NSString *name;
@end

@implementation RACScheduler

#pragma mark NSObject

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p> %@", self.class, self, self.name];
}

#pragma mark Initializers

- (instancetype)initWithName:(NSString *)name {
	self = [super init];

	if (name == nil) {
		_name = [NSString stringWithFormat:@"org.reactivecocoa.ReactiveObjC.%@.anonymousScheduler", self.class];
	} else {
		_name = [name copy];
	}

	return self;
}

#pragma mark Schedulers

+ (RACScheduler *)immediateScheduler {
	static dispatch_once_t onceToken;
	static RACScheduler *immediateScheduler;
	dispatch_once(&onceToken, ^{
		immediateScheduler = [[RACImmediateScheduler alloc] init];
	});
	
	return immediateScheduler;
}

+ (RACScheduler *)mainThreadScheduler {
	static dispatch_once_t onceToken;
	static RACScheduler *mainThreadScheduler;
	dispatch_once(&onceToken, ^{
		mainThreadScheduler = [[RACTargetQueueScheduler alloc] initWithName:@"org.reactivecocoa.ReactiveObjC.RACScheduler.mainThreadScheduler" targetQueue:dispatch_get_main_queue()];
	});
	
	return mainThreadScheduler;
}

+ (RACScheduler *)schedulerWithPriority:(RACSchedulerPriority)priority name:(NSString *)name {
	return [[RACTargetQueueScheduler alloc] initWithName:name targetQueue:dispatch_get_global_queue(priority, 0)];
}

+ (RACScheduler *)schedulerWithPriority:(RACSchedulerPriority)priority {
	return [self schedulerWithPriority:priority name:@"org.reactivecocoa.ReactiveObjC.RACScheduler.backgroundScheduler"];
}

+ (RACScheduler *)scheduler {
	return [self schedulerWithPriority:RACSchedulerPriorityDefault];
}

+ (RACScheduler *)subscriptionScheduler {
	static dispatch_once_t onceToken;
	static RACScheduler *subscriptionScheduler;
	dispatch_once(&onceToken, ^{
		subscriptionScheduler = [[RACSubscriptionScheduler alloc] init];
	});

	return subscriptionScheduler;
}

+ (BOOL)isOnMainThread {
	return [NSOperationQueue.currentQueue isEqual:NSOperationQueue.mainQueue] || [NSThread isMainThread];
}

+ (RACScheduler *)currentScheduler {
	RACScheduler *scheduler = NSThread.currentThread.threadDictionary[RACSchedulerCurrentSchedulerKey];
	if (scheduler != nil) return scheduler;
	if ([self.class isOnMainThread]) return RACScheduler.mainThreadScheduler;

	return nil;
}

#pragma mark Scheduling

- (RACDisposable *)schedule:(void (^)(void))block {
	NSCAssert(NO, @"%@ must be implemented by subclasses.", NSStringFromSelector(_cmd));
	return nil;
}

- (RACDisposable *)after:(NSDate *)date schedule:(void (^)(void))block {
	NSCAssert(NO, @"%@ must be implemented by subclasses.", NSStringFromSelector(_cmd));
	return nil;
}

- (RACDisposable *)afterDelay:(NSTimeInterval)delay schedule:(void (^)(void))block {
	return [self after:[NSDate dateWithTimeIntervalSinceNow:delay] schedule:block];
}

- (RACDisposable *)after:(NSDate *)date repeatingEvery:(NSTimeInterval)interval withLeeway:(NSTimeInterval)leeway schedule:(void (^)(void))block {
	NSCAssert(NO, @"%@ must be implemented by subclasses.", NSStringFromSelector(_cmd));
	return nil;
}

- (RACDisposable *)scheduleRecursiveBlock:(RACSchedulerRecursiveBlock)recursiveBlock {
	RACCompoundDisposable *disposable = [RACCompoundDisposable compoundDisposable];

	[self scheduleRecursiveBlock:[recursiveBlock copy] addingToDisposable:disposable];
	return disposable;
}

- (void)scheduleRecursiveBlock:(RACSchedulerRecursiveBlock)recursiveBlock addingToDisposable:(RACCompoundDisposable *)disposable {
	@autoreleasepool {
		RACCompoundDisposable *selfDisposable = [RACCompoundDisposable compoundDisposable];
		[disposable addDisposable:selfDisposable];

		__weak RACDisposable *weakSelfDisposable = selfDisposable;
        // 这里的代码在下个 runloop 被调用
		RACDisposable *schedulingDisposable = [self schedule:^{
			@autoreleasepool {
				// At this point, we've been invoked, so our disposable is now useless.
				[disposable removeDisposable:weakSelfDisposable];
			}

			if (disposable.disposed) return;

			void (^reallyReschedule)(void) = ^{
				if (disposable.disposed) return;
				[self scheduleRecursiveBlock:recursiveBlock addingToDisposable:disposable];
			};

			// Protects the variables below.
			//
			// This doesn't actually need to be __block qualified, but Clang
			// complains otherwise. :C
			__block NSLock *lock = [[NSLock alloc] init];
			lock.name = [NSString stringWithFormat:@"%@ %s", self, sel_getName(_cmd)];

			__block NSUInteger rescheduleCount = 0;

			// Set to YES once synchronous execution has finished. Further
			// rescheduling should occur immediately (rather than being
			// flattened). 如果在下面的 block 中，发现 rescheduleImmediately 为 YES，那么就是说 recursiveBlock 的执行是异步的，然后现在异步的执行已经回来了，就需要立刻执行 reallyReschedule
			__block BOOL rescheduleImmediately = NO;
            // 这里是执行递归 block 的地方
			@autoreleasepool {
				recursiveBlock(^{
                    // 这个 block 参数，是递归 block 决定要不要再次递归，如果要再次递归，就调用这个 recurse block
                    // 这个 recurse block 有可能是 recursiveBlock 在执行的过程中被调用，那么也就是同步调用
                    // 判断方法是看 rescheduleImmediately 是不是为 YES，如果还是 NO，说明没有被修改
                    // 如果是 YES，说明这个 recurse block 是被异步调用的，因为下面的代码 【sync】会被先调用
					[lock lock];
					BOOL immediate = rescheduleImmediately;
					if (!immediate) ++rescheduleCount;  // 如果是同步调用，就增加调用次数，之后在【sync】代码段中调用
					[lock unlock];

					if (immediate) reallyReschedule();  // 如果是异步调用，就需要在异步里执行下次递归操作
				});
			}
            // 【sync】 ：
			[lock lock];
			NSUInteger synchronousCount = rescheduleCount; // 如果是异步调用 rescheduleCount 的值还是 0
			rescheduleImmediately = YES;
			[lock unlock];

			for (NSUInteger i = 0; i < synchronousCount; i++) {
				reallyReschedule();
			}
		}];

		[selfDisposable addDisposable:schedulingDisposable];
	}
}

- (void)performAsCurrentScheduler:(void (^)(void))block {
	NSCParameterAssert(block != NULL);

	// If we're using a concurrent queue, we could end up in here concurrently,
	// in which case we *don't* want to clear the current scheduler immediately
	// after our block is done executing, but only *after* all our concurrent
	// invocations are done.

	RACScheduler *previousScheduler = RACScheduler.currentScheduler;
	NSThread.currentThread.threadDictionary[RACSchedulerCurrentSchedulerKey] = self;

	@autoreleasepool {
		block();
	}

	if (previousScheduler != nil) {
		NSThread.currentThread.threadDictionary[RACSchedulerCurrentSchedulerKey] = previousScheduler;
	} else {
		[NSThread.currentThread.threadDictionary removeObjectForKey:RACSchedulerCurrentSchedulerKey];
	}
}

@end
