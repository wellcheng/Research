//
//  RACSignal.m
//  ReactiveObjC
//
//  Created by Josh Abernathy on 3/15/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import "RACSignal.h"
#import "RACCompoundDisposable.h"
#import "RACDisposable.h"
#import "RACDynamicSignal.h"
#import "RACEmptySignal.h"
#import "RACErrorSignal.h"
#import "RACMulticastConnection.h"
#import "RACReplaySubject.h"
#import "RACReturnSignal.h"
#import "RACScheduler.h"
#import "RACSerialDisposable.h"
#import "RACSignal+Operations.h"
#import "RACSubject.h"
#import "RACSubscriber+Private.h"
#import "RACTuple.h"
#import <libkern/OSAtomic.h>

@implementation RACSignal

#pragma mark Lifecycle

+ (RACSignal *)createSignal:(RACDisposable * (^)(id<RACSubscriber> subscriber))didSubscribe {
    /// 内部用 Dynamic 子类承接所有任务
    return [RACDynamicSignal createSignal:didSubscribe];
}

+ (RACSignal *)error:(NSError *)error {
    return [RACErrorSignal error:error];
}

+ (RACSignal *)never {
    return [[self createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
        return nil;
    }] setNameWithFormat:@"+never"];
}

+ (RACSignal *)startEagerlyWithScheduler:(RACScheduler *)scheduler block:(void (^)(id<RACSubscriber> subscriber))block {
    NSCParameterAssert(scheduler != nil);
    NSCParameterAssert(block != NULL);
    
    RACSignal *signal = [self startLazilyWithScheduler:scheduler block:block];
    // Subscribe to force the lazy signal to call its block.
    [[signal publish] connect];
    return [signal setNameWithFormat:@"+startEagerlyWithScheduler: %@ block:", scheduler];
}

+ (RACSignal *)startLazilyWithScheduler:(RACScheduler *)scheduler block:(void (^)(id<RACSubscriber> subscriber))block {
    NSCParameterAssert(scheduler != nil);
    NSCParameterAssert(block != NULL);
    
    RACMulticastConnection *connection = [[RACSignal
                                           createSignal:^ id (id<RACSubscriber> subscriber) {
                                               block(subscriber);
                                               return nil;
                                           }]
                                          multicast:[RACReplaySubject subject]];
    
    return [[[RACSignal
              createSignal:^ id (id<RACSubscriber> subscriber) {
                  [connection.signal subscribe:subscriber];
                  [connection connect];
                  return nil;
              }]
             subscribeOn:scheduler]
            setNameWithFormat:@"+startLazilyWithScheduler: %@ block:", scheduler];
}

#pragma mark NSObject

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p> name: %@", self.class, self, self.name];
}

@end

@implementation RACSignal (RACStream)

+ (RACSignal *)empty {
    return [RACEmptySignal empty];
}

+ (RACSignal *)return:(id)value {
    return [RACReturnSignal return:value];
}

- (RACSignal *)bind:(RACSignalBindBlock (^)(void))block {
    NSCParameterAssert(block != NULL);
    
    /*
     * -bind: should:
     *
     * 1. Subscribe to the original signal of values.
     首先，订阅被 bind 的信号，以下称 origin signal，bind 之后，会返回一个 signal，称 return signal
     
     * 2. Any time the original signal sends a value, transform it using the binding block.
     只要 origin signal 发出 value，使用 bindBlock 进行转换，转换之后得到另一个新的 singal，以下成为 bind singal
     
     * 3. If the binding block returns a signal, subscribe to it, and pass all of its values through to the subscriber as they're received.
     如果转换后的 bind singal 不为 nil，那么就接着订阅它，并且将订阅后产生的所有 values 交给 return signal 的 receiver，发送出去
     如果转换后为 nil，那么就直接结束 return signal
     
     * 4. If the binding block asks the bind to terminate, complete the _original_ signal.
     如果 block 要求终止 bind ，也就是 stop = YES，那么就直接结束 return signal
     
     * 5. When _all_ signals complete, send completed to the subscriber.
     如果这个过程中所有转换后的 signal 都完成，那么就发送 completed 给 return subscriber 这个被订阅者
     *
     * If any signal sends an error at any point, send that to the subscriber.
     在这个过程中，所有的 error 都原封不动通过 return signal 发送，并发送后直接结束
     */
    
    // 1 - bind 最终会返回一个信号，下面看一下 bind 返回的这个信号做了什么事情
    return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
        // 2 - 首先执行 bind block，得到一个结果，类型是 bindBlock
        RACSignalBindBlock bindingBlock = block();
        
        __block volatile int32_t signalCount = 1;   // indicates self
        
        // 3 - 创建同一的 disposable
        RACCompoundDisposable *compoundDisposable = [RACCompoundDisposable compoundDisposable];
        
        // 4 - 创建 completedSignal 回调，当转换后的信号 完成时回调，
        void (^completeSignal)(RACDisposable *) = ^(RACDisposable *finishedDisposable) {
            //
            if (OSAtomicDecrement32Barrier(&signalCount) == 0) {
                // 所有被转换的信号已经完成了，那么自己也完成
                [subscriber sendCompleted];
                [compoundDisposable dispose];
            } else {
                [compoundDisposable removeDisposable:finishedDisposable];
            }
        };
        
        // 5- 创建添加信号的回调，转换后的信号 被添加时调用
        void (^addSignal)(RACSignal *) = ^(RACSignal *signal) {
            // singal 数量增加
            OSAtomicIncrement32Barrier(&signalCount);
            // serial disposable 包装了一个 disposable ，并且内部的 disposable 能被替换出来，如果这个 serial disposable 被 dispose 了，那么之后被赋值的 disposable 也会立刻被 disposable
            RACSerialDisposable *selfDisposable = [[RACSerialDisposable alloc] init];
            [compoundDisposable addDisposable:selfDisposable];
            
            // 订阅转换后的信号
            RACDisposable *disposable = [signal subscribeNext:^(id x) {
                // 转换信号，对于值，直接传递出去
                [subscriber sendNext:x];
            } error:^(NSError *error) {
                // 转换信号，对于错误，sendError
                // 并且结束整个 bind 过程
                [compoundDisposable dispose];
                [subscriber sendError:error];   // 因为转换出了 error，从而导致整个 subscribe 提前结束
            } completed:^{
                // 如果转换信号 完成了，就调用完成回调，
                // 并传入 dispose，保证与 compoundDisposable 一起被回收
                @autoreleasepool {
                    completeSignal(selfDisposable);
                }
            }];
            // addSignal 的 dispose 与 serial 绑定
            selfDisposable.disposable = disposable;
        };
        
        // 6 - 开启新的作用域
        @autoreleasepool {
            // 仍然先将 disposable 加入到 com
            RACSerialDisposable *selfDisposable = [[RACSerialDisposable alloc] init];
            [compoundDisposable addDisposable:selfDisposable];
            
            // 这里才是核心，开始订阅 self 这个 origin signal
            RACDisposable *bindingDisposable = [self subscribeNext:^(id x) {
                // Manually check disposal to handle synchronous errors.
                // 如果 compoundDisposable 已经被 dispsoe 了，那么就不用再处理无意义的事情了
                if (compoundDisposable.disposed) return;
                
                // 使用 bindBlock 转换 self 的 next 事件，并且传入 stop 参数，用于控制终止
                BOOL stop = NO;
                id signal = bindingBlock(x, &stop);
                
                @autoreleasepool {
                    // 将转换后的 signal 添加进来
                    if (signal != nil) addSignal(signal);
                    if (signal == nil || stop) {
                        // 当转换失败或者 stop 时，停止当前对 self 的继续 bind，并回收
                        [selfDisposable dispose];
                        // 调用完成回调，让 returnSignal 完成，同时进行回收，因为只有 add 之后，在 completeSignal 时，才会因为还有未完成的 转换信号，让 return signal 继续，这里因为 origin signal 在中间发生了一次转换 nil，导致提前结束
                        completeSignal(selfDisposable);
                    }
                }
            } error:^(NSError *error) {
                // 被 bind 的 signal 出错，也是回收并向 returnSignal 发出错误
                [compoundDisposable dispose];
                [subscriber sendError:error];
            } completed:^{
                // self 自己，也就是 origin 完成回调，让 returnSignal 完成，同时进行回收
                @autoreleasepool {
                    completeSignal(selfDisposable);
                }
            }];
            
            selfDisposable.disposable = bindingDisposable;
        }
        return compoundDisposable;
    }] setNameWithFormat:@"[%@] -bind:", self.name];
}
// 合并多个信号，需要等前面的信号发出完成时，才会订阅后面的那个
- (RACSignal *)concat:(RACSignal *)signal {
    // concat 与 bind 类似，都是返回一个新的信号
    return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
        RACCompoundDisposable *compoundDisposable = [[RACCompoundDisposable alloc] init];
        
        // 先订阅自己
        RACDisposable *sourceDisposable = [self subscribeNext:^(id x) {
            [subscriber sendNext:x];
        } error:^(NSError *error) {
            [subscriber sendError:error];
        } completed:^{
            // 只有在自己完成时，再订阅传入的参数信号
            RACDisposable *concattedDisposable = [signal subscribe:subscriber];
            [compoundDisposable addDisposable:concattedDisposable];
        }];
        
        [compoundDisposable addDisposable:sourceDisposable];
        return compoundDisposable;
    }] setNameWithFormat:@"[%@] -concat: %@", self.name, signal];
}

// 拉链方法，第一个信号的值与第二个信号的值组成一个元组作为新信号的第一个值
- (RACSignal *)zipWith:(RACSignal *)signal {
    NSCParameterAssert(signal != nil);
    // 也是创建一个新的信号
    return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
        __block BOOL selfCompleted = NO;
        NSMutableArray *selfValues = [NSMutableArray array];
        
        __block BOOL otherCompleted = NO;
        NSMutableArray *otherValues = [NSMutableArray array];
        
        void (^sendCompletedIfNecessary)(void) = ^{
            // 当两个信号有任一一个完成，并且值全部被处理，新信号就完成
            @synchronized (selfValues) {
                BOOL selfEmpty = (selfCompleted && selfValues.count == 0);
                BOOL otherEmpty = (otherCompleted && otherValues.count == 0);
                if (selfEmpty || otherEmpty) [subscriber sendCompleted];
            }
        };
        
        void (^sendNext)(void) = ^{
            @synchronized (selfValues) {
                if (selfValues.count == 0) return;
                if (otherValues.count == 0) return;
                
                // 只有当两个数组中都有值的时候，才发送一个元组
                RACTuple *tuple = RACTuplePack(selfValues[0], otherValues[0]);
                [selfValues removeObjectAtIndex:0];
                [otherValues removeObjectAtIndex:0];
                
                [subscriber sendNext:tuple];
                sendCompletedIfNecessary();
            }
        };
        
        // 先订阅自己
        RACDisposable *selfDisposable = [self subscribeNext:^(id x) {
            // 将自己的值保存起来
            @synchronized (selfValues) {
                [selfValues addObject:x ?: RACTupleNil.tupleNil];
                sendNext();
            }
        } error:^(NSError *error) {
            // 有 error 就让新信号也 error
            [subscriber sendError:error];
        } completed:^{
            // 完成之后
            @synchronized (selfValues) {
                selfCompleted = YES;
                sendCompletedIfNecessary();
            }
        }];
        // 接着订阅 other，与 self 思路一致
        RACDisposable *otherDisposable = [signal subscribeNext:^(id x) {
            @synchronized (selfValues) {
                [otherValues addObject:x ?: RACTupleNil.tupleNil];
                sendNext();
            }
        } error:^(NSError *error) {
            [subscriber sendError:error];
        } completed:^{
            @synchronized (selfValues) {
                otherCompleted = YES;
                sendCompletedIfNecessary();
            }
        }];
        // disposable 也合并
        return [RACDisposable disposableWithBlock:^{
            [selfDisposable dispose];
            [otherDisposable dispose];
        }];
    }] setNameWithFormat:@"[%@] -zipWith: %@", self.name, signal];
}

@end

@implementation RACSignal (Subscription)

- (RACDisposable *)subscribe:(id<RACSubscriber>)subscriber {
    NSCAssert(NO, @"This method must be overridden by subclasses");
    return nil;
}

- (RACDisposable *)subscribeNext:(void (^)(id x))nextBlock {
    NSCParameterAssert(nextBlock != NULL);
    
    RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:NULL completed:NULL];
    return [self subscribe:o];
}

- (RACDisposable *)subscribeNext:(void (^)(id x))nextBlock completed:(void (^)(void))completedBlock {
    NSCParameterAssert(nextBlock != NULL);
    NSCParameterAssert(completedBlock != NULL);
    
    RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:NULL completed:completedBlock];
    return [self subscribe:o];
}

- (RACDisposable *)subscribeNext:(void (^)(id x))nextBlock error:(void (^)(NSError *error))errorBlock completed:(void (^)(void))completedBlock {
    NSCParameterAssert(nextBlock != NULL);
    NSCParameterAssert(errorBlock != NULL);
    NSCParameterAssert(completedBlock != NULL);
    
    RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:errorBlock completed:completedBlock];
    return [self subscribe:o];
}

- (RACDisposable *)subscribeError:(void (^)(NSError *error))errorBlock {
    NSCParameterAssert(errorBlock != NULL);
    
    RACSubscriber *o = [RACSubscriber subscriberWithNext:NULL error:errorBlock completed:NULL];
    return [self subscribe:o];
}

- (RACDisposable *)subscribeCompleted:(void (^)(void))completedBlock {
    NSCParameterAssert(completedBlock != NULL);
    
    RACSubscriber *o = [RACSubscriber subscriberWithNext:NULL error:NULL completed:completedBlock];
    return [self subscribe:o];
}

- (RACDisposable *)subscribeNext:(void (^)(id x))nextBlock error:(void (^)(NSError *error))errorBlock {
    NSCParameterAssert(nextBlock != NULL);
    NSCParameterAssert(errorBlock != NULL);
    
    RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:errorBlock completed:NULL];
    return [self subscribe:o];
}

- (RACDisposable *)subscribeError:(void (^)(NSError *))errorBlock completed:(void (^)(void))completedBlock {
    NSCParameterAssert(completedBlock != NULL);
    NSCParameterAssert(errorBlock != NULL);
    
    RACSubscriber *o = [RACSubscriber subscriberWithNext:NULL error:errorBlock completed:completedBlock];
    return [self subscribe:o];
}

@end

@implementation RACSignal (Debugging)

- (RACSignal *)logAll {
    return [[[self logNext] logError] logCompleted];
}

- (RACSignal *)logNext {
    return [[self doNext:^(id x) {
        NSLog(@"%@ next: %@", self, x);
    }] setNameWithFormat:@"%@", self.name];
}

- (RACSignal *)logError {
    return [[self doError:^(NSError *error) {
        NSLog(@"%@ error: %@", self, error);
    }] setNameWithFormat:@"%@", self.name];
}

- (RACSignal *)logCompleted {
    return [[self doCompleted:^{
        NSLog(@"%@ completed", self);
    }] setNameWithFormat:@"%@", self.name];
}

@end

@implementation RACSignal (Testing)

static const NSTimeInterval RACSignalAsynchronousWaitTimeout = 10;

- (id)asynchronousFirstOrDefault:(id)defaultValue success:(BOOL *)success error:(NSError **)error {
    return [self asynchronousFirstOrDefault:defaultValue success:success error:error timeout:RACSignalAsynchronousWaitTimeout];
}

- (id)asynchronousFirstOrDefault:(id)defaultValue success:(BOOL *)success error:(NSError **)error timeout:(NSTimeInterval)timeout {
    NSCAssert([NSThread isMainThread], @"%s should only be used from the main thread", __func__);
    
    __block id result = defaultValue;
    __block BOOL done = NO;
    
    // Ensures that we don't pass values across thread boundaries by reference.
    __block NSError *localError;
    __block BOOL localSuccess = YES;
    
    [[[[self
        take:1]
       timeout:timeout onScheduler:[RACScheduler scheduler]]
      deliverOn:RACScheduler.mainThreadScheduler]
     subscribeNext:^(id x) {
         result = x;
         done = YES;
     } error:^(NSError *e) {
         if (!done) {
             localSuccess = NO;
             localError = e;
             done = YES;
         }
     } completed:^{
         done = YES;
     }];
    
    do {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    } while (!done);
    
    if (success != NULL) *success = localSuccess;
    if (error != NULL) *error = localError;
    
    return result;
}

- (BOOL)asynchronouslyWaitUntilCompleted:(NSError **)error timeout:(NSTimeInterval)timeout {
    BOOL success = NO;
    [[self ignoreValues] asynchronousFirstOrDefault:nil success:&success error:error timeout:timeout];
    return success;
}

- (BOOL)asynchronouslyWaitUntilCompleted:(NSError **)error {
    return [self asynchronouslyWaitUntilCompleted:error timeout:RACSignalAsynchronousWaitTimeout];
}

@end
