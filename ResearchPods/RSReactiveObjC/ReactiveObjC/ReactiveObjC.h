//
//  ReactiveObjC.h
//  ReactiveObjC
//
//  Created by Josh Abernathy on 3/5/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

//! Project version number for ReactiveObjC.
FOUNDATION_EXPORT double ReactiveObjCVersionNumber;

//! Project version string for ReactiveObjC.
FOUNDATION_EXPORT const unsigned char ReactiveObjCVersionString[];

#import <RSReactiveObjC/RACEXTKeyPathCoding.h>
#import <RSReactiveObjC/RACEXTScope.h>
#import <RSReactiveObjC/NSArray+RACSequenceAdditions.h>
#import <RSReactiveObjC/NSData+RACSupport.h>
#import <RSReactiveObjC/NSDictionary+RACSequenceAdditions.h>
#import <RSReactiveObjC/NSEnumerator+RACSequenceAdditions.h>
#import <RSReactiveObjC/NSFileHandle+RACSupport.h>
#import <RSReactiveObjC/NSNotificationCenter+RACSupport.h>
#import <RSReactiveObjC/NSObject+RACDeallocating.h>
#import <RSReactiveObjC/NSObject+RACLifting.h>
#import <RSReactiveObjC/NSObject+RACPropertySubscribing.h>
#import <RSReactiveObjC/NSObject+RACSelectorSignal.h>
#import <RSReactiveObjC/NSOrderedSet+RACSequenceAdditions.h>
#import <RSReactiveObjC/NSSet+RACSequenceAdditions.h>
#import <RSReactiveObjC/NSString+RACSequenceAdditions.h>
#import <RSReactiveObjC/NSString+RACSupport.h>
#import <RSReactiveObjC/NSIndexSet+RACSequenceAdditions.h>
#import <RSReactiveObjC/NSUserDefaults+RACSupport.h>
#import <RSReactiveObjC/RACBehaviorSubject.h>
#import <RSReactiveObjC/RACChannel.h>
#import <RSReactiveObjC/RACCommand.h>
#import <RSReactiveObjC/RACCompoundDisposable.h>
#import <RSReactiveObjC/RACDelegateProxy.h>
#import <RSReactiveObjC/RACDisposable.h>
#import <RSReactiveObjC/RACEvent.h>
#import <RSReactiveObjC/RACGroupedSignal.h>
#import <RSReactiveObjC/RACKVOChannel.h>
#import <RSReactiveObjC/RACMulticastConnection.h>
#import <RSReactiveObjC/RACQueueScheduler.h>
#import <RSReactiveObjC/RACQueueScheduler+Subclass.h>
#import <RSReactiveObjC/RACReplaySubject.h>
#import <RSReactiveObjC/RACScheduler.h>
#import <RSReactiveObjC/RACScheduler+Subclass.h>
#import <RSReactiveObjC/RACScopedDisposable.h>
#import <RSReactiveObjC/RACSequence.h>
#import <RSReactiveObjC/RACSerialDisposable.h>
#import <RSReactiveObjC/RACSignal+Operations.h>
#import <RSReactiveObjC/RACSignal.h>
#import <RSReactiveObjC/RACStream.h>
#import <RSReactiveObjC/RACSubject.h>
#import <RSReactiveObjC/RACSubscriber.h>
#import <RSReactiveObjC/RACSubscriptingAssignmentTrampoline.h>
#import <RSReactiveObjC/RACTargetQueueScheduler.h>
#import <RSReactiveObjC/RACTestScheduler.h>
#import <RSReactiveObjC/RACTuple.h>
#import <RSReactiveObjC/RACUnit.h>

#if TARGET_OS_WATCH
#elif TARGET_OS_IOS || TARGET_OS_TV
	#import <RSReactiveObjC/UIBarButtonItem+RACCommandSupport.h>
	#import <RSReactiveObjC/UIButton+RACCommandSupport.h>
	#import <RSReactiveObjC/UICollectionReusableView+RACSignalSupport.h>
	#import <RSReactiveObjC/UIControl+RACSignalSupport.h>
	#import <RSReactiveObjC/UIGestureRecognizer+RACSignalSupport.h>
	#import <RSReactiveObjC/UISegmentedControl+RACSignalSupport.h>
	#import <RSReactiveObjC/UITableViewCell+RACSignalSupport.h>
	#import <RSReactiveObjC/UITableViewHeaderFooterView+RACSignalSupport.h>
	#import <RSReactiveObjC/UITextField+RACSignalSupport.h>
	#import <RSReactiveObjC/UITextView+RACSignalSupport.h>

	#if TARGET_OS_IOS
		#import <RSReactiveObjC/NSURLConnection+RACSupport.h>
		#import <RSReactiveObjC/UIStepper+RACSignalSupport.h>
		#import <RSReactiveObjC/UIDatePicker+RACSignalSupport.h>
		#import <RSReactiveObjC/UIAlertView+RACSignalSupport.h>
		#import <RSReactiveObjC/UIActionSheet+RACSignalSupport.h>
		#import <RSReactiveObjC/MKAnnotationView+RACSignalSupport.h>
		#import <RSReactiveObjC/UIImagePickerController+RACSignalSupport.h>
		#import <RSReactiveObjC/UIRefreshControl+RACCommandSupport.h>
		#import <RSReactiveObjC/UISlider+RACSignalSupport.h>
		#import <RSReactiveObjC/UISwitch+RACSignalSupport.h>
	#endif
#elif TARGET_OS_MAC
	#import <RSReactiveObjC/NSControl+RACCommandSupport.h>
	#import <RSReactiveObjC/NSControl+RACTextSignalSupport.h>
	#import <RSReactiveObjC/NSObject+RACAppKitBindings.h>
	#import <RSReactiveObjC/NSText+RACSignalSupport.h>
	#import <RSReactiveObjC/NSURLConnection+RACSupport.h>
#endif
