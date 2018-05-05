//
//  RSRacBind.m
//  RAC
//
//  Created by charvel on 2018/5/5.
//  Copyright © 2018年 charvel. All rights reserved.
//

#import "RSRacOperations.h"
#import <RSReactiveObjC/ReactiveObjC.h>

@implementation RSRacOperations
+ (void)bind
{
    RACSignal *originSignal = [RACSignal createSignal:
                               ^RACDisposable *(id<RACSubscriber> subscriber)
                               {
                                   [subscriber sendNext:@1];
                                   [subscriber sendNext:@2];
                                   [subscriber sendNext:@3];
                                   [subscriber sendCompleted];
                                   return [RACDisposable disposableWithBlock:^{
                                       NSLog(@"origin signal dispose");
                                   }];
                               }];
    
    RACSignal *bindSignal = [originSignal bind:^RACSignalBindBlock{
        // bind 方法需要返回一个 bindBlock，这个 bindBlock 用来做转换
        return ^RACSignal *(NSNumber *value, BOOL *stop){
            // bindBlock 传入两个值，一个是 origin signal 产生的值，另一个值用来控制是否停止
            value = @(value.integerValue * 2);
            // 这里返回了信号，会被再次订阅
            if (value.integerValue == 3) {
                return [RACSignal error:[NSError errorWithDomain:@"" code:-111 userInfo:nil]];
            }
            if (value.integerValue == 5) {
                return nil;
            }
            return [RACSignal return:value];
        };
    }];
    
    [bindSignal subscribeNext:^(id x) {
        NSLog(@"bindSignal subscribe value = %@", x);
    }];

}

+ (void)concat {
    RACSignal *signal = [RACSignal createSignal:
                         ^RACDisposable *(id<RACSubscriber> subscriber)
                         {
                             [subscriber sendNext:@1];
                             [subscriber sendCompleted];
                             return [RACDisposable disposableWithBlock:^{
                                 NSLog(@"signal dispose");
                             }];
                         }];
    
    
    RACSignal *signals = [RACSignal createSignal:
                          ^RACDisposable *(id<RACSubscriber> subscriber)
                          {
                              [subscriber sendNext:@2];
                              [subscriber sendNext:@3];
                              [subscriber sendNext:@6];
                              [subscriber sendCompleted];
                              return [RACDisposable disposableWithBlock:^{
                                  NSLog(@"signal dispose");
                              }];
                          }];
    
    RACSignal *concatSignal = [signal concat:signals];
    
    [concatSignal subscribeNext:^(id x) {
        NSLog(@"subscribe value = %@", x);
    }];
}

+ (void)repeat
{
    NSError *err = [NSError errorWithDomain:@"" code:-1 userInfo:nil];
    RACSignal *oriSignal = [RACSignal createSignal:^RACDisposable * _Nullable(id<RACSubscriber>  _Nonnull subscriber){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [subscriber sendNext:@"1"];
            [subscriber sendNext:@"2"];
            [subscriber sendNext:@"3"];
            [subscriber sendError:err];
            [subscriber sendCompleted];
        });
        return [RACDisposable disposableWithBlock:^{
            NSLog(@"oriSignal dispose");
        }];
    }];
    
    [[oriSignal retry:5] subscribeNext:^(id  _Nullable x) {
        NSLog(@"repeat %@", x);
    } error:^(NSError * _Nullable error) {
        NSLog(@"repeat error %@", error);
    } completed:^{
        NSLog(@"repeat completed");
    }];
}
@end
