//
//  RACStream.m
//  ReactiveObjC
//
//  Created by Justin Spahr-Summers on 2012-10-31.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import "RACStream.h"
#import "NSObject+RACDescription.h"
#import "RACBlockTrampoline.h"
#import "RACTuple.h"

@implementation RACStream

#pragma mark Lifecycle

- (instancetype)init {
	self = [super init];

	self.name = @"";
	return self;
}

#pragma mark Abstract methods

+ (__kindof RACStream *)empty {
	NSString *reason = [NSString stringWithFormat:@"%@ must be overridden by subclasses", NSStringFromSelector(_cmd)];
	@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:reason userInfo:nil];
}

- (__kindof RACStream *)bind:(RACStreamBindBlock (^)(void))block {
	NSString *reason = [NSString stringWithFormat:@"%@ must be overridden by subclasses", NSStringFromSelector(_cmd)];
	@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:reason userInfo:nil];
}

+ (__kindof RACStream *)return:(id)value {
	NSString *reason = [NSString stringWithFormat:@"%@ must be overridden by subclasses", NSStringFromSelector(_cmd)];
	@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:reason userInfo:nil];
}

- (__kindof RACStream *)concat:(RACStream *)stream {
	NSString *reason = [NSString stringWithFormat:@"%@ must be overridden by subclasses", NSStringFromSelector(_cmd)];
	@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:reason userInfo:nil];
}

- (__kindof RACStream *)zipWith:(RACStream *)stream {
	NSString *reason = [NSString stringWithFormat:@"%@ must be overridden by subclasses", NSStringFromSelector(_cmd)];
	@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:reason userInfo:nil];
}

#pragma mark Naming

- (instancetype)setNameWithFormat:(NSString *)format, ... {
	if (getenv("RAC_DEBUG_SIGNAL_NAMES") == NULL) return self;

	NSCParameterAssert(format != nil);

	va_list args;
	va_start(args, format);

	NSString *str = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);

	self.name = str;
	return self;
}

@end

@implementation RACStream (Operations)

// flattenMap 的实现其实就是 bind
- (__kindof RACStream *)flattenMap:(__kindof RACStream * (^)(id value))block {
	Class class = self.class;
    
    // flattenMap 的实现中，其实就是将 map 的 block 作为 bind 的 tansform block
	return [[self bind:^{
        // 这里其实是要求 return signal 的，不过没有写明，但是下面的 assert 中还是要保证是 signal
		return ^(id value, BOOL *stop) {
            // 这里有一点，就是过滤了 nil，也就是 block 返回的信号中存在 nil 时，需要使用 empty 替换
			id stream = block(value) ?: [class empty];
			NSCAssert([stream isKindOfClass:RACStream.class], @"Value returned from -flattenMap: is not a stream: %@", stream);

			return stream;
		};
	}] setNameWithFormat:@"[%@] -flattenMap:", self.name];
}

- (__kindof RACStream *)flatten {
	return [[self flattenMap:^(id value) {
		return value;
	}] setNameWithFormat:@"[%@] -flatten", self.name];
}

// 对自己调用 map ，其实就是先把自己的 value 包装为 signal，调用 fattenmap 拍平这些 signal
// 因为包装的时候用了 return，所以根传统的 map 是一样的，就是 value replace value
- (__kindof RACStream *)map:(id (^)(id value))block {
	NSCParameterAssert(block != nil);

	Class class = self.class;
	
	return [[self flattenMap:^(id value) {
        // flattenMap blcok 是，把 block 执行后的结果，包装起来，作为一个 value 直接 return
        // 因为 faltten 内部是 bind，会把 signal 继续订阅，相当于拍平
		return [class return:block(value)];
	}] setNameWithFormat:@"[%@] -map:", self.name];
}

// Map replace 其实就是 map 的变种，对 self 的 value 进行 map，全部替换为 object
- (__kindof RACStream *)mapReplace:(id)object {
	return [[self map:^(id _) {
		return object;
	}] setNameWithFormat:@"[%@] -mapReplace: %@", self.name, RACDescription(object)];
}

- (__kindof RACStream *)combinePreviousWithStart:(id)start reduce:(id (^)(id previous, id next))reduceBlock {
	NSCParameterAssert(reduceBlock != NULL);
	return [[[self
		scanWithStart:RACTuplePack(start)
		reduce:^(RACTuple *previousTuple, id next) {
			id value = reduceBlock(previousTuple[0], next);
			return RACTuplePack(next, value);
		}]
		map:^(RACTuple *tuple) {
			return tuple[1];
		}]
		setNameWithFormat:@"[%@] -combinePreviousWithStart: %@ reduce:", self.name, RACDescription(start)];
}

// filter 也会返回一个新的 signal，内部仍然是 flatten map
- (__kindof RACStream *)filter:(BOOL (^)(id value))block {
	NSCParameterAssert(block != nil);

	Class class = self.class;
	
	return [[self flattenMap:^ id (id value) {
        // 不过在这里做了处理，如果 filter 的 block 返回了 YES，就返回 value，如果是 NO，就用 empty 替换，从而最终被过滤掉
		if (block(value)) {
			return [class return:value];
		} else {
			return class.empty;
		}
	}] setNameWithFormat:@"[%@] -filter:", self.name];
}

// ignore 就是 filter 的另一个，只 filter 掉与 value 匹配的值
- (__kindof RACStream *)ignore:(id)value {
	return [[self filter:^ BOOL (id innerValue) {
		return innerValue != value && ![innerValue isEqual:value];
	}] setNameWithFormat:@"[%@] -ignore: %@", self.name, RACDescription(value)];
}

// reduce 是聚合，不过 reduce 要求 map 的 value是 tuple 类型，从而可以利用 reduceBlock 对元组进行处理
- (__kindof RACStream *)reduceEach:(RACReduceBlock)reduceBlock {
	NSCParameterAssert(reduceBlock != nil);

	__weak RACStream *stream __attribute__((unused)) = self;
	return [[self map:^(RACTuple *t) {
        // 这里要求【value from stream must be a tuple】
		NSCAssert([t isKindOfClass:RACTuple.class], @"Value from stream %@ is not a tuple: %@", stream, t);
        // 这里是利用多参数对 tuple 应用 reduceBlock
		return [RACBlockTrampoline invokeBlock:reduceBlock withArguments:t];
	}] setNameWithFormat:@"[%@] -reduceEach:", self.name];
}

// Start With 其实就是在 signal 发出信号之前先用一个 value 作为开始
- (__kindof RACStream *)startWith:(id)value {
	return [[[self.class return:value]
		concat:self]
		setNameWithFormat:@"[%@] -startWith: %@", self.name, RACDescription(value)];
}

// skip 也用到了 bind，能够跳过最前面的几个 value
- (__kindof RACStream *)skip:(NSUInteger)skipCount {
	Class class = self.class;
	
	return [[self bind:^{
		__block NSUInteger skipped = 0;

		return ^(id value, BOOL *stop) {
			if (skipped >= skipCount) return [class return:value];
            // 远离就是需要 skip 的几个，都用 empty 代替
			skipped++;
			return class.empty;
		};
	}] setNameWithFormat:@"[%@] -skip: %lu", self.name, (unsigned long)skipCount];
}

// take 说白了就是 skip 的变种，只获取前面的几个 value
- (__kindof RACStream *)take:(NSUInteger)count {
	Class class = self.class;
	
	if (count == 0) return class.empty;

	return [[self bind:^{
		__block NSUInteger taken = 0;

		return ^ id (id value, BOOL *stop) {
			if (taken < count) {
				++taken;
                // take 足够的 value 后就 stop ，让 bind 返回的 signal 完成
				if (taken == count) *stop = YES;
				return [class return:value];
			} else {
				return nil;
			}
		};
	}] setNameWithFormat:@"[%@] -take: %lu", self.name, (unsigned long)count];
}

+ (__kindof RACStream *)join:(id<NSFastEnumeration>)streams block:(RACStream * (^)(id, id))block {
	RACStream *current = nil;

	// Creates streams of successively larger tuples by combining the input
	// streams one-by-one.
	for (RACStream *stream in streams) {
		// For the first stream, just wrap its values in a RACTuple. That way,
		// if only one stream is given, the result is still a stream of tuples.
		if (current == nil) {
			current = [stream map:^(id x) {
				return RACTuplePack(x);
			}];

			continue;
		}

		current = block(current, stream);
	}

	if (current == nil) return [self empty];

	return [current map:^(RACTuple *xs) {
		// Right now, each value is contained in its own tuple, sorta like:
		//
		// (((1), 2), 3)
		//
		// We need to unwrap all the layers and create a tuple out of the result.
		NSMutableArray *values = [[NSMutableArray alloc] init];

		while (xs != nil) {
			[values insertObject:xs.last ?: RACTupleNil.tupleNil atIndex:0];
			xs = (xs.count > 1 ? xs.first : nil);
		}

		return [RACTuple tupleWithObjectsFromArray:values];
	}];
}

+ (__kindof RACStream *)zip:(id<NSFastEnumeration>)streams {
	return [[self join:streams block:^(RACStream *left, RACStream *right) {
		return [left zipWith:right];
	}] setNameWithFormat:@"+zip: %@", streams];
}

+ (__kindof RACStream *)zip:(id<NSFastEnumeration>)streams reduce:(RACGenericReduceBlock)reduceBlock {
	NSCParameterAssert(reduceBlock != nil);

	RACStream *result = [self zip:streams];

	// Although we assert this condition above, older versions of this method
	// supported this argument being nil. Avoid crashing Release builds of
	// apps that depended on that.
	if (reduceBlock != nil) result = [result reduceEach:reduceBlock];

	return [result setNameWithFormat:@"+zip: %@ reduce:", streams];
}

+ (__kindof RACStream *)concat:(id<NSFastEnumeration>)streams {
	RACStream *result = self.empty;
	for (RACStream *stream in streams) {
		result = [result concat:stream];
	}

	return [result setNameWithFormat:@"+concat: %@", streams];
}

// scan 无 index 版本
- (__kindof RACStream *)scanWithStart:(id)startingValue reduce:(id (^)(id running, id next))reduceBlock {
	NSCParameterAssert(reduceBlock != nil);

	return [[self
		scanWithStart:startingValue
		reduceWithIndex:^(id running, id next, NSUInteger index) {
			return reduceBlock(running, next);
		}]
		setNameWithFormat:@"[%@] -scanWithStart: %@ reduce:", self.name, RACDescription(startingValue)];
}

// 扫描所有元素，用 startValue 作为初始值，然后挨个用 reduce block 转换为下一个 running
- (__kindof RACStream *)scanWithStart:(id)startingValue reduceWithIndex:(id (^)(id, id, NSUInteger))reduceBlock {
	NSCParameterAssert(reduceBlock != nil);

	Class class = self.class;

	return [[self bind:^{
		__block id running = startingValue;
		__block NSUInteger index = 0;

		return ^(id value, BOOL *stop) {
			running = reduceBlock(running, value, index++);
			return [class return:running];
		};
	}] setNameWithFormat:@"[%@] -scanWithStart: %@ reduceWithIndex:", self.name, RACDescription(startingValue)];
}

- (__kindof RACStream *)takeUntilBlock:(BOOL (^)(id x))predicate {
	NSCParameterAssert(predicate != nil);

	Class class = self.class;
	
	return [[self bind:^{
		return ^ id (id value, BOOL *stop) {
			if (predicate(value)) return nil;

			return [class return:value];
		};
	}] setNameWithFormat:@"[%@] -takeUntilBlock:", self.name];
}

- (__kindof RACStream *)takeWhileBlock:(BOOL (^)(id x))predicate {
	NSCParameterAssert(predicate != nil);

	return [[self takeUntilBlock:^ BOOL (id x) {
		return !predicate(x);
	}] setNameWithFormat:@"[%@] -takeWhileBlock:", self.name];
}

- (__kindof RACStream *)skipUntilBlock:(BOOL (^)(id x))predicate {
	NSCParameterAssert(predicate != nil);

	Class class = self.class;
	
	return [[self bind:^{
		__block BOOL skipping = YES;

		return ^ id (id value, BOOL *stop) {
			if (skipping) {
				if (predicate(value)) {
					skipping = NO;
				} else {
					return class.empty;
				}
			}

			return [class return:value];
		};
	}] setNameWithFormat:@"[%@] -skipUntilBlock:", self.name];
}

- (__kindof RACStream *)skipWhileBlock:(BOOL (^)(id x))predicate {
	NSCParameterAssert(predicate != nil);

	return [[self skipUntilBlock:^ BOOL (id x) {
		return !predicate(x);
	}] setNameWithFormat:@"[%@] -skipWhileBlock:", self.name];
}

- (__kindof RACStream *)distinctUntilChanged {
	Class class = self.class;

	return [[self bind:^{
		__block id lastValue = nil;
		__block BOOL initial = YES;

		return ^(id x, BOOL *stop) {
			if (!initial && (lastValue == x || [x isEqual:lastValue])) return [class empty];

			initial = NO;
			lastValue = x;
			return [class return:x];
		};
	}] setNameWithFormat:@"[%@] -distinctUntilChanged", self.name];
}

@end
