//
//  RACCommand.m
//  ReactiveObjC
//
//  Created by Josh Abernathy on 3/3/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import "RACCommand.h"
#import <RSReactiveObjC/RACEXTScope.h>
#import "NSArray+RACSequenceAdditions.h"
#import "NSObject+RACDeallocating.h"
#import "NSObject+RACDescription.h"
#import "NSObject+RACPropertySubscribing.h"
#import "RACMulticastConnection.h"
#import "RACReplaySubject.h"
#import "RACScheduler.h"
#import "RACSequence.h"
#import "RACSignal+Operations.h"
#import <libkern/OSAtomic.h>

NSString * const RACCommandErrorDomain = @"RACCommandErrorDomain";
NSString * const RACUnderlyingCommandErrorKey = @"RACUnderlyingCommandErrorKey";

const NSInteger RACCommandErrorNotEnabled = 1;

@interface RACCommand () {
	// Atomic backing variable for `allowsConcurrentExecution`.
	volatile uint32_t _allowsConcurrentExecution;
}

/// A subject that sends added execution signals.
// 已经添加的任务，也就是 command 的 block 返回的那个 signal 都会作为这个 subject 的 value 发送出来
@property (nonatomic, strong, readonly) RACSubject *addedExecutionSignalsSubject;

/// A subject that sends the new value of `allowsConcurrentExecution` whenever it changes.
// 是否允许并发
@property (nonatomic, strong, readonly) RACSubject *allowsConcurrentExecutionSubject;

// `enabled`, but without a hop to the main thread.
//
// Values from this signal may arrive on any thread.
// 是不是可以立即执行一个新任务
@property (nonatomic, strong, readonly) RACSignal *immediateEnabled;

// The signal block that the receiver was initialized with.
// command 需要执行的 block ，描述了执行任务
@property (nonatomic, copy, readonly) RACSignal * (^signalBlock)(id input);

@end

@implementation RACCommand

#pragma mark Properties

- (BOOL)allowsConcurrentExecution {
	return _allowsConcurrentExecution != 0;
}

- (void)setAllowsConcurrentExecution:(BOOL)allowed {
	if (allowed) {
        // _allowsConcurrentExecution 的值等于 它自己与 1 的原子逻辑或，其实就是原子赋值
		OSAtomicOr32Barrier(1, &_allowsConcurrentExecution);
	} else {
		OSAtomicAnd32Barrier(0, &_allowsConcurrentExecution);
	}
    // subject 发送信号
	[self.allowsConcurrentExecutionSubject sendNext:@(_allowsConcurrentExecution)];
}

#pragma mark Lifecycle

- (instancetype)init {
	NSCAssert(NO, @"Use -initWithSignalBlock: instead");
	return nil;
}

- (instancetype)initWithSignalBlock:(RACSignal<id> * (^)(id input))signalBlock {
	return [self initWithEnabled:nil signalBlock:signalBlock];
}

- (void)dealloc {
	[_addedExecutionSignalsSubject sendCompleted];
	[_allowsConcurrentExecutionSubject sendCompleted];
}

// 
- (instancetype)initWithEnabled:(RACSignal *)enabledSignal signalBlock:(RACSignal<id> * (^)(id input))signalBlock {
	NSCParameterAssert(signalBlock != nil);

	self = [super init];

    // 活跃的任务
	_addedExecutionSignalsSubject = [RACSubject new];
    // 是否允许并发
	_allowsConcurrentExecutionSubject = [RACSubject new];
    // 任务是啥
	_signalBlock = [signalBlock copy];

    // 已添加的 signal 进行 map，map 主要是去除 error 信号
    // 然后分发在主线程上
    // _executionSignals 的 value 是信号，这里没有 flatten，_executionSignals 是 signals of signal
	_executionSignals = [[[self.addedExecutionSignalsSubject
		map:^(RACSignal *signal) {
			return [signal catchTo:[RACSignal empty]];
		}]
		deliverOn:RACScheduler.mainThreadScheduler]
		setNameWithFormat:@"%@ -executionSignals", self];
	
	// `errors` needs to be multicasted so that it picks up all
	// `activeExecutionSignals` that are added.
	//
	// In other words, if someone subscribes to `errors` _after_ an execution
	// has started, it should still receive any error from that execution.
    // 为了保证 发生 Error 时， 之后订阅的信号也能收到 error，这里使用热信号
    // errorsConnection 保存了 added 原始信号
	RACMulticastConnection *errorsConnection = [[[self.addedExecutionSignalsSubject
		flattenMap:^(RACSignal *signal) {
			return [[signal
				ignoreValues]
				catch:^(NSError *error) {
					return [RACSignal return:error];
				}];
		}]
		deliverOn:RACScheduler.mainThreadScheduler]
		publish];
	
    // errors 信号是 connection 的 multicasted 信号
	_errors = [errorsConnection.signal setNameWithFormat:@"%@ -errors", self];
    // connect 的时候，added singal 的所有 error 事件都会转到 _error 这个 subject 上
	[errorsConnection connect];

    // immediateExecuting 表示是不是可以立即执行
	RACSignal *immediateExecuting = [[[[self.addedExecutionSignalsSubject
		flattenMap:^(RACSignal *signal) {
            // 先 startWith @1，让信号数量 + 1，
            // 接着先让 signal 忽略所有的 error，使用 then 只处理 completed 事件
            // 、return [RACSignal return:@-1];、 是个 defer block，也就是当 signal 完成时，这里触发，返回一个 -1
			return [[[signal
				catchTo:[RACSignal empty]]
				then:^{
					return [RACSignal return:@-1];
				}]
				startWith:@1];
            // 一开始先返回一个 1 表示有信号被加入并处理
            // 使用 then 机制，表示信号完成时返回 -1 抵消原来的 + 1 操作
		}]
		scanWithStart:@0 reduce:^(NSNumber *running, NSNumber *next) {
            // 从 0 开始，逐步 reduce 上面的值，也就是这里返回的值 ，在信号增加和减少时会不断的变化
			return @(running.integerValue + next.integerValue);
		}]
		map:^(NSNumber *count) {
            // 只要还有正在执行的 signal ，就返回 YES
			return @(count.integerValue > 0);
		}]
		startWith:@NO]; // 一开始，是没有信号在执行的

    // 一开始是没有任务执行
    // 接着看 immediateExecuting 是不是有变化，如果有变化，并且与上次不一样，那么就表示 excuting 的状态也变化了
    // 需要 replayLast 记住最后一个状态
	_executing = [[[[[immediateExecuting
		deliverOn:RACScheduler.mainThreadScheduler]
		// This is useful before the first value arrives on the main thread.
		startWith:@NO]
		distinctUntilChanged]
		replayLast]
		setNameWithFormat:@"%@ -executing", self];
	
    // if 信号一开始是 No，也就是返回 else 信号，即是否允许更多，要看是不是有信号执行，有信号执行就不能在执行新的
    // 如果允许并发变为 YES，那么就执行 then，始终允许执行，因为都并发了，自然可以执行更多的任务
	RACSignal *moreExecutionsAllowed = [RACSignal
		if:[self.allowsConcurrentExecutionSubject startWith:@NO]
		then:[RACSignal return:@YES]
		else:[immediateExecuting not]];
	
    // 条件信号为空时，创建一个，条件永远为真
	if (enabledSignal == nil) {
		enabledSignal = [RACSignal return:@YES];
	} else {
        // 条件信号存在时，默认先以 YES 开始
		enabledSignal = [enabledSignal startWith:@YES];
	}
	
    // 能不能立即执行新任务，条件信号 && 可以执行下一个，都成立，才可以
	_immediateEnabled = [[[[RACSignal
		combineLatest:@[ enabledSignal, moreExecutionsAllowed ]]
		and]
		takeUntil:self.rac_willDeallocSignal]
		replayLast];
	
    // command 是否可用，先看能够立即执行下一个任务，接着把这个值作为 enable 结果发送出去
    // 接着等待 immediate 的后续值，看是不是有了变化，即要做好后续的更新
	_enabled = [[[[[self.immediateEnabled
		take:1]
		concat:[[self.immediateEnabled skip:1] deliverOn:RACScheduler.mainThreadScheduler]]
		distinctUntilChanged]
		replayLast]
		setNameWithFormat:@"%@ -enabled", self];

	return self;
}

#pragma mark Execution

- (RACSignal *)execute:(id)input {
	// `immediateEnabled` is guaranteed to send a value upon subscription, so
	// -first is acceptable here.
	BOOL enabled = [[self.immediateEnabled first] boolValue];
	if (!enabled) {
        // 不被允许的情况下执行就报错，而且是真正的错误，不是发生在 errorSignal 上的任务错误
        // 即这个错误是执行这个操作错误
		NSError *error = [NSError errorWithDomain:RACCommandErrorDomain code:RACCommandErrorNotEnabled userInfo:@{
			NSLocalizedDescriptionKey: NSLocalizedString(@"The command is disabled and cannot be executed", nil),
			RACUnderlyingCommandErrorKey: self
		}];

		return [RACSignal error:error];
	}

    // 执行任务 block ，得到一个 signal
	RACSignal *signal = self.signalBlock(input);
	NSCAssert(signal != nil, @"nil signal returned from signal block for value: %@", input);

	// We subscribe to the signal on the main thread so that it occurs _after_
	// -addActiveExecutionSignal: completes below.
	//
	// This means that `executing` and `enabled` will send updated values before
	// the signal actually starts performing work.
    
    // 使用 connect 将任务 signal 订阅到 subject 上
	RACMulticastConnection *connection = [[signal
		subscribeOn:RACScheduler.mainThreadScheduler]
		multicast:[RACReplaySubject subject]];
	// 添加活跃的信号
	[self.addedExecutionSignalsSubject sendNext:connection.signal];
    // 信号连接，开始订阅 block signal
	[connection connect];
    // 返回订阅之后的结果 signal
	return [connection.signal setNameWithFormat:@"%@ -execute: %@", self, RACDescription(input)];
}

@end
