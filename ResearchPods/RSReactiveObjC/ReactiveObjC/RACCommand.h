//
//  RACCommand.h
//  ReactiveObjC
//
//  Created by Josh Abernathy on 3/3/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

@class RACSignal<__covariant ValueType>;

NS_ASSUME_NONNULL_BEGIN

/// The domain for errors originating within `RACCommand`.
extern NSString * const RACCommandErrorDomain;

/// -execute: was invoked while the command was disabled.
extern const NSInteger RACCommandErrorNotEnabled;

/// A `userInfo` key for an error, associated with the `RACCommand` that the
/// error originated from.
///
/// This is included only when the error code is `RACCommandErrorNotEnabled`.
extern NSString * const RACUnderlyingCommandErrorKey;

/// A command is a signal triggered in response to some action, typically
/// UI-related.
@interface RACCommand<__contravariant InputType, __covariant ValueType> : NSObject

/**
    高阶信号，信号的信号，
    可以使用 switchToLasted 获取最后一个信号的值，进行降阶
 */
/// A signal of the signals returned by successful invocations of -execute:
/// (i.e., while the receiver is `enabled`).
///
/// Errors will be automatically caught upon the inner signals, and sent upon
/// `errors` instead. If you _want_ to receive inner errors, use -execute: or
/// -[RACSignal materialize].
/// 
/// Only executions that begin _after_ subscription will be sent upon this
/// signal. All inner signals will arrive upon the main thread.
@property (nonatomic, strong, readonly) RACSignal<RACSignal<ValueType> *> *executionSignals;

/// A signal of whether this command is currently executing.
// 表示当前 command 是否正在执行
/// This will send YES whenever -execute: is invoked and the created signal has
/// not yet terminated. Once all executions have terminated, `executing` will
/// send NO.
// 这个信号一开始是 YES，然后只有所有的 command 都执行完毕才变为 YES，只要有任务执行在 command 上，就为 NO
///
/// This signal will send its current value upon subscription, and then all
/// future values on the main thread.
@property (nonatomic, strong, readonly) RACSignal<NSNumber *> *executing;

/// A signal of whether this command is able to execute.
///
/// This will send NO if:
///
///  - The command was created with an `enabledSignal`, and NO is sent upon that
///    signal, or
///  - `allowsConcurrentExecution` is NO and the command has started executing.
// enabled 表示 command 是否可以执行任务，如果条件信号为 NO，那么肯定不能执行
// 如果条件为 YES，如果没有任务在执行，那么就可以
// 如果有新任务，还要看是不是可以并发
///
/// Once the above conditions are no longer met, the signal will send YES.
///
/// This signal will send its current value upon subscription, and then all
/// future values on the main thread.
@property (nonatomic, strong, readonly) RACSignal<NSNumber *> *enabled;

/// Forwards any errors that occur within signals returned by -execute:.
///
/// When an error occurs on a signal returned from -execute:, this signal will
/// send the associated NSError value as a `next` event (since an `error` event
/// would terminate the stream).
//
//  所有 command 执行期间的 error 都会转移到 error 这个信号上，而且会包装为 next 事件
///
/// After subscription, this signal will send all future errors on the main
/// thread.
@property (nonatomic, strong, readonly) RACSignal<NSError *> *errors;

/// Whether the command allows multiple executions to proceed concurrently.
///
/// The default value for this property is NO.
@property (atomic, assign) BOOL allowsConcurrentExecution;

/// Invokes -initWithEnabled:signalBlock: with a nil `enabledSignal`.
- (instancetype)initWithSignalBlock:(RACSignal<ValueType> * (^)(InputType _Nullable input))signalBlock;

/// Initializes a command that is conditionally enabled.
/// 使用一个条件 signal 来初始化 command
///
/// This is the designated initializer for this class.
///
/// enabledSignal - A signal of BOOLs which indicate whether the command should
///                 be enabled. `enabled` will be based on the latest value sent
///                 from this signal. Before any values are sent, `enabled` will
///                 default to YES. This argument may be nil.
//  enabledSignal   条件 signal 用来指示当前的 command 是否能够执行。
//                  signal 的最后一次值会保存起来
//                  默认值是 yes
/// signalBlock   - A block which will map each input value (passed to -execute:)
///                 to a signal of work. The returned signal will be multicasted
///                 to a replay subject, sent on `executionSignals`, then
///                 subscribed to synchronously. Neither the block nor the
///                 returned signal may be nil.
//                  singalBlock 是当 command 执行时，会被调用，block 返回的 signal 会被发送到 replay 的热信号上
//                  也就是 executionSignals
- (instancetype)initWithEnabled:(nullable RACSignal<NSNumber *> *)enabledSignal signalBlock:(RACSignal<ValueType> * (^)(InputType _Nullable input))signalBlock;

/// If the receiver is enabled, this method will:
///
///  1. Invoke the `signalBlock` given at the time of initialization.
//      调用 signalBlock
///  2. Multicast the returned signal to a RACReplaySubject.
//      返回 subject signal
///  3. Send the multicasted signal on `executionSignals`.
//      在 executionSignals 上广播
///  4. Subscribe (connect) to the original signal on the main thread.
//      主线程链接到 origin signal
///
/// input - The input value to pass to the receiver's `signalBlock`. This may be
///         nil.
///
/// Returns the multicasted signal, after subscription. If the receiver is not
/// enabled, returns a signal that will send an error with code
/// RACCommandErrorNotEnabled.
- (RACSignal<ValueType> *)execute:(nullable InputType)input;

@end

NS_ASSUME_NONNULL_END
