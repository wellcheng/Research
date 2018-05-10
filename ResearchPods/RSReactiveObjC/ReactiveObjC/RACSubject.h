//
//  RACSubject.h
//  ReactiveObjC
//
//  Created by Josh Abernathy on 3/9/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import "RACSignal.h"
#import "RACSubscriber.h"

NS_ASSUME_NONNULL_BEGIN

/// A subject can be thought of as a signal that you can manually control by
/// sending next, completed, and error.
///
/// They're most helpful in bridging the non-RAC world to RAC, since they let you
/// manually control the sending of events.

// subject 可以被认为是一个能够手动去控制 send next 、error、completed 事件的 signal
@interface RACSubject<ValueType> : RACSignal<ValueType> <RACSubscriber>

/// Returns a new subject.
+ (instancetype)subject;

// Redeclaration of the RACSubscriber method. Made in order to specify a generic type.
- (void)sendNext:(nullable ValueType)value;

@end

NS_ASSUME_NONNULL_END
