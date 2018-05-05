//
//  RACDynamicSignal.m
//  ReactiveObjC
//
//  Created by Justin Spahr-Summers on 2013-10-10.
//  Copyright (c) 2013 GitHub, Inc. All rights reserved.
//

#import "RACDynamicSignal.h"
#import <RSReactiveObjC/RACEXTScope.h>
#import "RACCompoundDisposable.h"
#import "RACPassthroughSubscriber.h"
#import "RACScheduler+Private.h"
#import "RACSubscriber.h"
#import <libkern/OSAtomic.h>

@interface RACDynamicSignal ()

// The block to invoke for each subscriber.
@property (nonatomic, copy, readonly) RACDisposable * (^didSubscribe)(id<RACSubscriber> subscriber);

@end

@implementation RACDynamicSignal

#pragma mark Lifecycle

+ (RACSignal *)createSignal:(RACDisposable * (^)(id<RACSubscriber> subscriber))didSubscribe {
    // 先创建一个 dynamic signal，然后将 didSubscribe block 赋值过去就好了。
    RACDynamicSignal *signal = [[self alloc] init];
    // 后续该 signal 被订阅时，会自动被调用这个 block
    signal->_didSubscribe = [didSubscribe copy];
    return [signal setNameWithFormat:@"+createSignal:"];
}

#pragma mark Managing Subscribers

- (RACDisposable *)subscribe:(id<RACSubscriber>)subscriber {
    // 当 Signal 被订阅时，就走到了这里
    NSCParameterAssert(subscriber != nil);
    
    // 先创建一个混合 disposable
    RACCompoundDisposable *disposable = [RACCompoundDisposable compoundDisposable];
    // 1、subscriber 是一个 RACSubscriber 的实例，只是简单包装了几个 next error completed 回调
    // 2、再次将 subscriber 用 RACPassthroughSubscriber 包装一下，并且把 signal 也包装进去
    // 3、把 subscriber 的 disposable 加入到 自己的 disposable  中，自己 dispose 时也 dispose RACPassthroughSubscriber 中的 innerSubscribe
    // 如果 innerSubscribe 先 dispose ，就把 innerSubscribe 的 disposable 从自己中移除
    subscriber = [[RACPassthroughSubscriber alloc] initWithSubscriber:subscriber signal:self disposable:disposable];
    
    // RACPassthroughSubscriber 其实就是一个转移的东西，外面表现得像个 subscribe ，其实活都交给内部的 inner 干
    
    if (self.didSubscribe != NULL) {
        // schedule 就是一个简单的派发器，最终还是执行这个 block
        RACDisposable *schedulingDisposable = [RACScheduler.subscriptionScheduler schedule:^{
            // subscriber 已经创建好了，现在由于 signal 被订阅了，需要执行 block，把 subscribe 作为参数传递进去就好了
            /**
             *    didSubscribe 这个 block 就是派发信号的地方
             *    我们在编码时写了大量的 sendNext sendCompleted 方法
             *     都会在这一步被调用
             *    RACPassthroughSubscriber 在调用这几个 block 时，最终还是分发给了内部的 inner，现在去 inner 看一下
             */
            RACDisposable *innerDisposable = self.didSubscribe(subscriber);
            // 得到的 disposable 加入到 Dynamic 这个大的 disposable 中
            [disposable addDisposable:innerDisposable];
        }];
        // 派发器也需要 dispose
        [disposable addDisposable:schedulingDisposable];
    }
    
    return disposable;
}

@end
