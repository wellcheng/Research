//
//  RACChannel.m
//  ReactiveObjC
//
//  Created by Uri Baghin on 01/01/2013.
//  Copyright (c) 2013 GitHub, Inc. All rights reserved.
//

#import "RACChannel.h"
#import "RACDisposable.h"
#import "RACReplaySubject.h"
#import "RACSignal+Operations.h"

@interface RACChannelTerminal<ValueType> ()

/// The values for this terminal.
@property (nonatomic, strong, readonly) RACSignal<ValueType> *values;

/// A subscriber will will send values to the other terminal.
@property (nonatomic, strong, readonly) id<RACSubscriber> otherTerminal;

- (instancetype)initWithValues:(RACSignal<ValueType> *)values otherTerminal:(id<RACSubscriber>)otherTerminal;

@end

@implementation RACChannel

- (instancetype)init {
	self = [super init];

	// We don't want any starting value from the leadingSubject, but we do want
	// error and completion to be replayed.
    // leading 是指保存一个的 replay
	RACReplaySubject *leadingSubject = [[RACReplaySubject replaySubjectWithCapacity:0] setNameWithFormat:@"leadingSubject"];
    // follow 保存一个
	RACReplaySubject *followingSubject = [[RACReplaySubject replaySubjectWithCapacity:1] setNameWithFormat:@"followingSubject"];

	// Propagate errors and completion to everything.
    // leading 只发送 error 到 follow
	[[leadingSubject ignoreValues] subscribe:followingSubject];
    // follow 发送 error 和 complete 到 leading
	[[followingSubject ignoreValues] subscribe:leadingSubject];

    // 两个之间相互打通
	_leadingTerminal = [[[RACChannelTerminal alloc] initWithValues:leadingSubject otherTerminal:followingSubject] setNameWithFormat:@"leadingTerminal"];
	_followingTerminal = [[[RACChannelTerminal alloc] initWithValues:followingSubject otherTerminal:leadingSubject] setNameWithFormat:@"followingTerminal"];

	return self;
}

@end

@implementation RACChannelTerminal

#pragma mark Lifecycle

- (instancetype)initWithValues:(RACSignal *)values otherTerminal:(id<RACSubscriber>)otherTerminal {
	NSCParameterAssert(values != nil);
	NSCParameterAssert(otherTerminal != nil);

	self = [super init];

	_values = values;
	_otherTerminal = otherTerminal;

	return self;
}

#pragma mark RACSignal

- (RACDisposable *)subscribe:(id<RACSubscriber>)subscriber {
	return [self.values subscribe:subscriber];
}

#pragma mark <RACSubscriber>

- (void)sendNext:(id)value {
	[self.otherTerminal sendNext:value];
}

- (void)sendError:(NSError *)error {
	[self.otherTerminal sendError:error];
}

- (void)sendCompleted {
	[self.otherTerminal sendCompleted];
}

- (void)didSubscribeWithDisposable:(RACCompoundDisposable *)disposable {
	[self.otherTerminal didSubscribeWithDisposable:disposable];
}

@end
