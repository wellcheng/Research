//
//  RSRacConcat.m
//  RAC
//
//  Created by charvel on 2018/5/5.
//  Copyright © 2018年 charvel. All rights reserved.
//

#import "RSRacConcat.h"
#import <RSReactiveObjC/ReactiveObjC.h>

@implementation RSRacConcat
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
@end
