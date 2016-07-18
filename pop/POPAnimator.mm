/**
 Copyright (c) 2014-present, Facebook, Inc.
 All rights reserved.
 
 This source code is licensed under the BSD-style license found in the
 LICENSE file in the root directory of this source tree. An additional grant
 of patent rights can be found in the PATENTS file in the same directory.
 */

#import "POPAnimator.h"
#import "POPAnimatorPrivate.h"

#import <list>
#import <vector>

#if !TARGET_OS_IPHONE
#import <libkern/OSAtomic.h>
#endif

#import <objc/objc-auto.h>

#import <QuartzCore/QuartzCore.h>

#import "POPAnimation.h"
#import "POPAnimationExtras.h"
#import "POPBasicAnimationInternal.h"
#import "POPDecayAnimation.h"
#import "POPAnimationProxy.h"
#import "POPAnimatablePropertyInternal.h"
#import "POPGroupAnimation.h"
#import "POPGroupAnimationInternal.h"

using namespace std;
using namespace POP;

#define ENABLE_LOGGING_DEBUG 0
#define ENABLE_LOGGING_INFO 0

#if ENABLE_LOGGING_DEBUG
#define FBLogAnimDebug NSLog
#else
#define FBLogAnimDebug(...)
#endif

#if ENABLE_LOGGING_INFO
#define FBLogAnimInfo NSLog
#else
#define FBLogAnimInfo(...)
#endif

class POPAnimatorItem
{
public:
  id __weak object;
  NSString *key;
  POPAnimation *animation;
  NSInteger refCount;
  id __unsafe_unretained unretainedObject;

  POPAnimatorItem(id o, NSString *k, POPAnimation *a) POP_NOTHROW
  {
    object = o;
    key = [k copy];
    animation = a;
    refCount = 1;
    unretainedObject = o;
  }

  ~POPAnimatorItem()
  {
  }

  bool operator==(const POPAnimatorItem& o) const {
    return unretainedObject == o.unretainedObject && animation == o.animation && [key isEqualToString:o.key];
  }

};

typedef std::shared_ptr<POPAnimatorItem> POPAnimatorItemRef;
typedef std::shared_ptr<const POPAnimatorItem> POPAnimatorItemConstRef;

typedef std::list<POPAnimatorItemRef> POPAnimatorItemList;
typedef POPAnimatorItemList::iterator POPAnimatorItemListIterator;
typedef POPAnimatorItemList::const_iterator POPAnimatorItemListConstIterator;

static BOOL _disableBackgroundThread = YES;

@interface POPAnimator ()
{
#if TARGET_OS_IPHONE
  CADisplayLink *_displayLink;
#else
  CVDisplayLinkRef _displayLink;
  int32_t _enqueuedRender;
#endif
  POPAnimatorItemList _list;
  CFMutableDictionaryRef _dict;
  NSMutableArray *_observers;
  POPAnimatorItemList _pendingList;
  CFRunLoopObserverRef _pendingListObserver;
  CFTimeInterval _slowMotionStartTime;
  CFTimeInterval _slowMotionLastTime;
  CFTimeInterval _slowMotionAccumulator;
  CFTimeInterval _beginTime;
  pthread_mutex_t _lock;
  BOOL _disableDisplayLink;
  NSMapTable* _proxyAnimatorMap;
}
@end

@implementation POPAnimator
@synthesize delegate = _delegate;
@synthesize disableDisplayLink = _disableDisplayLink;
@synthesize beginTime = _beginTime;

#if !TARGET_OS_IPHONE
static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp *now, const CVTimeStamp *outputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *context)
{
  if (_disableBackgroundThread) {
    __unsafe_unretained POPAnimator *pa = (__bridge POPAnimator *)context;
    int32_t* enqueuedRender = &pa->_enqueuedRender;
    if (*enqueuedRender == 0) {
      OSAtomicIncrement32(enqueuedRender);
      dispatch_async(dispatch_get_main_queue(), ^{
        [(__bridge POPAnimator*)context render];
        OSAtomicDecrement32(enqueuedRender);
      });
    }
  } else {
    [(__bridge POPAnimator*)context render];
  }
  return kCVReturnSuccess;
}
#endif

// call while holding lock
static void updateDisplayLink(POPAnimator *self)
{
    if ( !self->_displayLink )
        return;
    
  BOOL paused = (0 == self->_observers.count && self->_list.empty()) || self->_disableDisplayLink;

#if TARGET_OS_IPHONE
  if (paused != self->_displayLink.paused) {
    FBLogAnimInfo(paused ? @"pausing display link" : @"unpausing display link");
    self->_displayLink.paused = paused;
  }
#else
  if (paused == CVDisplayLinkIsRunning(self->_displayLink)) {
    FBLogAnimInfo(paused ? @"pausing display link" : @"unpausing display link");
    if (paused) {
      CVDisplayLinkStop(self->_displayLink);
    } else {
      CVDisplayLinkStart(self->_displayLink);
    }
  }
#endif
}

static void updateAnimatable(id obj, POPPropertyAnimationState *anim, bool shouldAvoidExtraneousWrite = false)
{
  // handle user-initiated stop or pause; hault animation
  if (!anim->active || anim->paused)
    return;

  if (anim->hasValue()) {
    pop_animatable_write_block write = anim->property.writeBlock;
    if (NULL == write)
      return;

    // current animation value
    VectorRef currentVec = anim->currentValue();

    if (!anim->additive) {

      // if avoiding extraneous writes and we have a read block defined
      if (shouldAvoidExtraneousWrite) {

        pop_animatable_read_block read = anim->property.readBlock;
        if (read) {
          // compare current animation value with object value
          Vector4r currentValue = currentVec->vector4r();
          Vector4r objectValue = read_values(read, obj, anim->valueCount);
          if (objectValue == currentValue) {
            return;
          }
        }
      }
      
      // update previous values; support animation convergence
      anim->previous2Vec = anim->previousVec;
      anim->previousVec = currentVec;

      // write value
      write(obj, currentVec->data());
      if (anim->tracing) {
        [anim->tracer writePropertyValue:POPBox(currentVec, anim->valueType, true)];
      }
    } else {
      pop_animatable_read_block read = anim->property.readBlock;
      NSCAssert(read, @"additive requires an animatable property readBlock");
      if (NULL == read) {
        return;
      }

      // object value
      Vector4r objectValue = read_values(read, obj, anim->valueCount);

      // current value
      Vector4r currentValue = currentVec->vector4r();
      
      // determine animation change
      if (anim->previousVec) {
        Vector4r previousValue = anim->previousVec->vector4r();
        currentValue -= previousValue;
      }

      // avoid writing no change
      if (shouldAvoidExtraneousWrite && currentValue == Vector4r::Zero()) {
        return;
      }
      
      // add to object value
      currentValue += objectValue;
      
      // update previous values; support animation convergence
      anim->previous2Vec = anim->previousVec;
      anim->previousVec = currentVec;
      
      // write value
      write(obj, currentValue.data());
      if (anim->tracing) {
        [anim->tracer writePropertyValue:POPBox(currentVec, anim->valueType, true)];
      }
    }
  }
}

static void applyAnimationTime(id obj, POPAnimationState *state, CFTimeInterval time)
{
  if (!state->advanceTime(time, obj)) {
    return;
  }
  
  POPPropertyAnimationState *ps = dynamic_cast<POPPropertyAnimationState*>(state);
  if (NULL != ps) {
    updateAnimatable(obj, ps);
  }
  
  state->delegateApply();
}

static void applyAnimationToValue(id obj, POPAnimationState *state)
{
  POPPropertyAnimationState *ps = dynamic_cast<POPPropertyAnimationState*>(state);

  if (NULL != ps) {
    
    // finalize progress
    ps->finalizeProgress();
    
    // write to value, updating only if needed
    updateAnimatable(obj, ps, true);
  }
  
  state->delegateApply();
}

static POPAnimation *deleteDictEntry(POPAnimator *self, id __unsafe_unretained obj, NSString *key, BOOL cleanup = YES)
{
  POPAnimation *anim = nil;

  // lock
  pthread_mutex_lock(&self->_lock);

  NSMutableDictionary *keyAnimationsDict = (__bridge id)CFDictionaryGetValue(self->_dict, (__bridge void *)obj);
  if (keyAnimationsDict) {

    anim = keyAnimationsDict[key];
    if (anim) {

      // remove key
      [keyAnimationsDict removeObjectForKey:key];

      // cleanup empty dictionaries
      if (cleanup && 0 == keyAnimationsDict.count) {
        CFDictionaryRemoveValue(self->_dict, (__bridge void *)obj);
      }
    }
  }

  // unlock
  pthread_mutex_unlock(&self->_lock);
  return anim;
}

static void stopAndCleanup(POPAnimator *self, POPAnimatorItemRef item, bool shouldRemove, bool finished)
{
  // remove
  if (shouldRemove) {
    deleteDictEntry(self, item->unretainedObject, item->key);
  }

  // stop
  POPAnimationState *state = POPAnimationGetState(item->animation);
  state->stop(shouldRemove, finished);

  if (shouldRemove) {
    // lock
    pthread_mutex_lock(&self->_lock);

    // find item in list
    // may have already been removed on animationDidStop:
    POPAnimatorItemListIterator find_iter = find(self->_list.begin(), self->_list.end(), item);
    BOOL found = find_iter != self->_list.end();

    if (found) {
      self->_list.erase(find_iter);
    }

    // unlock
    pthread_mutex_unlock(&self->_lock);
  }
}

+ (id)sharedAnimator
{
  static POPAnimator* _animator = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _animator = [[POPAnimator alloc] initWithoutDisplayLink];
  });
  return _animator;
}

+ (BOOL)disableBackgroundThread
{
  return _disableBackgroundThread;
}

+ (void)setDisableBackgroundThread:(BOOL)flag
{
  _disableBackgroundThread = flag;
}

#pragma mark - Lifecycle

- (id)initWithoutDisplayLink
{
    self = [super init];
    if (nil == self) return nil;

    _dict = POPDictionaryCreateMutableWeakPointerToStrongObject(5);
    _proxyAnimatorMap = [NSMapTable weakToWeakObjectsMapTable];
    pthread_mutex_init(&_lock, NULL);
    
    return self;
}

- (id)init
{
  self = [super init];
  if (nil == self) return nil;

#if TARGET_OS_IPHONE
  _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(render)];
  _displayLink.paused = YES;
  [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
#else
  CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
  CVDisplayLinkSetOutputCallback(_displayLink, displayLinkCallback, (__bridge void *)self);
#endif

  _dict = POPDictionaryCreateMutableWeakPointerToStrongObject(5);
  _proxyAnimatorMap = [NSMapTable weakToWeakObjectsMapTable];
  pthread_mutex_init(&_lock, NULL);

  return self;
}

- (void)dealloc
{
#if TARGET_OS_IPHONE
  [_displayLink invalidate];
#else
  CVDisplayLinkStop(_displayLink);
  CVDisplayLinkRelease(_displayLink);
#endif
  [self _clearPendingListObserver];
    pthread_mutex_destroy(&_lock);
}

#pragma mark - Utility

- (void)_processPendingList
{
  // rendering pending animations
  CFTimeInterval time = [self _currentRenderTime];
  [self _renderTime:(0 != _beginTime) ? _beginTime : time items:_pendingList];

  // lock
  pthread_mutex_lock(&_lock);

  // clear list and observer
  _pendingList.clear();
  [self _clearPendingListObserver];

  // unlock
  pthread_mutex_unlock(&_lock);
}

- (void)_clearPendingListObserver
{
  if (_pendingListObserver) {
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), _pendingListObserver, kCFRunLoopCommonModes);
    CFRelease(_pendingListObserver);
    _pendingListObserver = NULL;
  }
}

- (void)_scheduleProcessPendingList
{
  // see WebKit for magic numbers, eg http://trac.webkit.org/changeset/166540
  static const CFIndex CATransactionCommitRunLoopOrder = 2000000;
  static const CFIndex POPAnimationApplyRunLoopOrder = CATransactionCommitRunLoopOrder - 1;

  // lock
  pthread_mutex_lock(&_lock);

  if (!_pendingListObserver) {
    __weak POPAnimator *weakSelf = self;

    _pendingListObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, false, POPAnimationApplyRunLoopOrder, ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
      [weakSelf _processPendingList];
    });

    if (_pendingListObserver) {
      CFRunLoopAddObserver(CFRunLoopGetMain(), _pendingListObserver,  kCFRunLoopCommonModes);
    }
  }

  // unlock
  pthread_mutex_unlock(&_lock);
}

- (void)_renderTime:(CFTimeInterval)time items:(std::list<POPAnimatorItemRef>)items
{
  // begin transaction with actions disabled
  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  // notify delegate
  __strong __typeof__(_delegate) delegate = _delegate;
  [delegate animatorWillAnimate:self];

  // lock
  pthread_mutex_lock(&_lock);

  // count active animations
  const NSUInteger count = items.size();
  if (0 == count) {
    // unlock
    pthread_mutex_unlock(&_lock);
  } else {
    // copy list into vector
    std::vector<POPAnimatorItemRef> vector{ items.begin(), items.end() };

    // unlock
    pthread_mutex_unlock(&_lock);

    for (auto item : vector) {
      [self _renderTime:time item:item];
    }
  }

  // notify observers
  for (id observer in self.observers) {
    [observer animatorDidAnimate:(id)self];
  }

  // lock
  pthread_mutex_lock(&_lock);

  // update display link
  updateDisplayLink(self);

  // unlock
  pthread_mutex_unlock(&_lock);

  // notify delegate and commit
  [delegate animatorDidAnimate:self];
  [CATransaction commit];
}

- (void)_renderTime:(CFTimeInterval)time item:(POPAnimatorItemRef)item
{
  id obj = item->object;
  POPAnimation *anim = item->animation;
  POPAnimationState *state = POPAnimationGetState(anim);

  if (nil == obj) {
    // object exists not; stop animating
    NSAssert(item->unretainedObject, @"object should exist");
    stopAndCleanup(self, item, true, false);
  } else {

    // start if needed
    state->startIfNeeded(obj, time, _slowMotionAccumulator);

    // only run active, not paused animations
    if (state->active && !state->paused) {
      // object exists; animate
      applyAnimationTime(obj, state, time);

      FBLogAnimDebug(@"time:%f running:%@", time, item->animation);
      if (state->isDone()) {
        // set end value
        applyAnimationToValue(obj, state);

        state->repeatCount--;
        if (state->repeatForever || state->repeatCount > 0) {
          if ([anim isKindOfClass:[POPPropertyAnimation class]]) {
            POPPropertyAnimation *propAnim = (POPPropertyAnimation *)anim;
            id oldFromValue = propAnim.fromValue;
            propAnim.fromValue = propAnim.toValue;

            if (state->autoreverses) {
              if (state->tracing) {
                [state->tracer autoreversed];
              }

              if (state->type == kPOPAnimationDecay) {
                POPDecayAnimation *decayAnimation = (POPDecayAnimation *)propAnim;
                decayAnimation.velocity = [decayAnimation reversedVelocity];
              } else {
                propAnim.toValue = oldFromValue;
              }
            } else {
              if (state->type == kPOPAnimationDecay) {
                POPDecayAnimation *decayAnimation = (POPDecayAnimation *)propAnim;
                id originalVelocity = decayAnimation.originalVelocity;
                decayAnimation.velocity = originalVelocity;
              } else {
                propAnim.fromValue = oldFromValue;
              }
            }
          }

          state->stop(NO, NO);
          state->reset(true);

          state->startIfNeeded(obj, time, _slowMotionAccumulator);
        } else {
          stopAndCleanup(self, item, state->removedOnCompletion, YES);
        }
      }
    }
  }
}

#pragma mark - API

- (NSArray *)observers
{
  // lock
  pthread_mutex_lock(&_lock);

  // get observers
  NSArray *observers = 0 != _observers.count ? [_observers copy] : nil;

  // unlock
  pthread_mutex_unlock(&_lock);
  return observers;
}

- (POPAnimatableProperty*)customAnimatablePropertyForObject:(id)obj keyPath:(NSString*)keyPath
{
  POPAnimatableProperty* property = nil;
  
  // support animationPropertyFor<keyPath>
  NSMutableString *propertyName = [NSMutableString string];
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  for ( NSString* part in parts )
  {
    NSString* partValue = [part stringByReplacingCharactersInRange:NSMakeRange(0,1) withString:[[part substringToIndex:1] capitalizedString]];
    [propertyName appendString:partValue];
  }
  
  NSString *methodName = [@"animationPropertyFor" stringByAppendingString:propertyName];
  SEL selector = NSSelectorFromString(methodName);
  if ( [obj respondsToSelector:selector] )
  {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    property = [obj performSelector:selector];
#pragma clang diagnostic pop
  }
  
  return property;
}

- (void)addAnimation:(POPAnimation *)anim forObject:(id)obj key:(NSString *)key
{
  if (!anim || !obj) {
    return;
  }

  // support arbitrarily many nil keys
  if (!key) {
    key = [[NSUUID UUID] UUIDString];
  }
  
  // support for default property
  if ( [anim isKindOfClass:[POPPropertyAnimation class]] ) {
    POPPropertyAnimation* propAnim = (POPPropertyAnimation*)anim;
    if ( propAnim.keyPath.length ) {
      
      // support animationPropertyFor<keyPath>
      propAnim.property = [self customAnimatablePropertyForObject:obj keyPath:propAnim.keyPath];
      
      // support for automatic properties
      if ( !propAnim.property )
      {
        id  val = [obj valueForKeyPath:propAnim.keyPath];
        if ( val ) {
          POPValueType  valueType = POPSelectValueType( val, kPOPAnimatableSupportTypes, POP_ARRAY_COUNT(kPOPAnimatableSupportTypes) );
          propAnim.property = [POPAnimatableProperty propertyWithName:[NSString stringWithFormat:@"%p:%@", obj, propAnim.keyPath] keyPath:propAnim.keyPath valueType:valueType];
        }
      }
    }
  }
  
  // lock
  pthread_mutex_lock(&_lock);

  // get key, animation dict associated with object
  NSMutableDictionary *keyAnimationDict = (__bridge id)CFDictionaryGetValue(_dict, (__bridge void *)obj);

  // update associated animation state
  if (nil == keyAnimationDict) {
    keyAnimationDict = [NSMutableDictionary dictionary];
    CFDictionarySetValue(_dict, (__bridge void *)obj, (__bridge void *)keyAnimationDict);
  } else {
    // if the animation instance already exists, avoid cancelling only to restart
    POPAnimation *existingAnim = keyAnimationDict[key];
    if (existingAnim) {
      // unlock
      pthread_mutex_unlock(&_lock);

      if (existingAnim == anim) {
        return;
      }
      [self removeAnimationForObject:obj key:key cleanupDict:NO];
        
      // lock
      pthread_mutex_lock(&_lock);
    }
  }
  keyAnimationDict[key] = anim;

  // create entry after potential removal
  POPAnimatorItemRef item(new POPAnimatorItem(obj, key, anim));

  // add to list and pending list
  _list.push_back(item);
  _pendingList.push_back(item);

  // support animation re-use, reset all animation state
  POPAnimationGetState(anim)->reset(true);

  // update display link
  updateDisplayLink(self);

  // unlock
  pthread_mutex_unlock(&_lock);

  // schedule runloop processing of pending animations
  [self _scheduleProcessPendingList];
}

- (void)removeAllAnimationsForObject:(id)obj
{
  // lock
  pthread_mutex_lock(&_lock);

  NSArray *animations = [(__bridge id)CFDictionaryGetValue(_dict, (__bridge void *)obj) allValues];
  CFDictionaryRemoveValue(_dict, (__bridge void *)obj);

  // unlock
  pthread_mutex_unlock(&_lock);

  if (0 == animations.count) {
    return;
  }

  NSHashTable *animationSet = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:animations.count];
  for (id animation in animations) {
    [animationSet addObject:animation];
  }

  // lock
  pthread_mutex_lock(&_lock);

  POPAnimatorItemRef item;
  for (auto iter = _list.begin(); iter != _list.end();) {
    item = *iter;
    if(![animationSet containsObject:item->animation]) {
      iter++;
    } else {
      iter = _list.erase(iter);
    }
  }

  // unlock
  pthread_mutex_unlock(&_lock);

  for (POPAnimation *anim in animations) {
    POPAnimationState *state = POPAnimationGetState(anim);
    state->stop(true, !state->active);
  }
}

- (void)removeAnimationForObject:(id)obj key:(NSString *)key cleanupDict:(BOOL)cleanupDict
{
  POPAnimation *anim = deleteDictEntry(self, obj, key, cleanupDict);
  if (nil == anim) {
    return;
  }

  // lock
  pthread_mutex_lock(&_lock);

  // remove from list
  POPAnimatorItemRef item;
  for (auto iter = _list.begin(); iter != _list.end();) {
    item = *iter;
    if(anim == item->animation) {
      _list.erase(iter);
      break;
    } else {
      iter++;
    }
  }

  // remove from pending list
  for (auto iter = _pendingList.begin(); iter != _pendingList.end();) {
    item = *iter;
    if(anim == item->animation) {
      _pendingList.erase(iter);
      break;
    } else {
      iter++;
    }
  }

  // unlock
  pthread_mutex_unlock(&_lock);

  // stop animation and callout
  POPAnimationState *state = POPAnimationGetState(anim);
  if ( state->type == kPOPAnimationGroup ) {
    NSArray* subkeys = [(POPGroupAnimation*)anim animationKeys];
    for ( NSString* subKey in subkeys )
      [self removeAnimationForObject:obj key:subKey cleanupDict:YES];
  }
  state->stop(true, (!state->active && !state->paused));
}

- (void)removeAnimationForObject:(id)obj key:(NSString *)key
{
  [self removeAnimationForObject:obj key:key cleanupDict:YES];
}

- (NSArray *)animationKeysForObject:(id)obj
{
  // lock
  pthread_mutex_lock(&_lock);

  // get keys
  NSArray *keys = [(__bridge id)CFDictionaryGetValue(_dict, (__bridge void *)obj) allKeys];

  // unlock
  pthread_mutex_unlock(&_lock);
  return keys;
}

- (NSArray*)animationsForObject:(id)obj
{
  // lock
  pthread_mutex_lock(&_lock);
  
  // lookup animation
  NSDictionary *keyAnimationsDict = (__bridge id)CFDictionaryGetValue(_dict, (__bridge void *)obj);
  NSArray* animations = keyAnimationsDict.allValues;

  // unlock
  pthread_mutex_unlock(&_lock);
  return animations;
}

- (id)animationProxyForObject:(id)obj
{
  // lock
  pthread_mutex_lock(&_lock);
  
  // lookup animation
  POPAnimationProxy *proxy = [_proxyAnimatorMap objectForKey:obj];
  if ( !proxy )
  {
    proxy = [[POPAnimationProxy alloc] initWithObject:obj];
    [_proxyAnimatorMap setObject:proxy forKey:obj];
  }
  
  // unlock
  pthread_mutex_unlock(&_lock);
  return proxy;
}

- (id)animationForObject:(id)obj key:(NSString *)key
{
  // lock
  pthread_mutex_lock(&_lock);

  // lookup animation
  NSDictionary *keyAnimationsDict = (__bridge id)CFDictionaryGetValue(_dict, (__bridge void *)obj);
  POPAnimation *animation = keyAnimationsDict[key];

  // unlock
  pthread_mutex_unlock(&_lock);
  return animation;
}

- (CFTimeInterval)_currentRenderTime
{
  CFTimeInterval time = CACurrentMediaTime();

#if TARGET_IPHONE_SIMULATOR
  // support slow-motion animations
  time += _slowMotionAccumulator;
  float f = POPAnimationDragCoefficient();

  if (f > 1.0) {
    if (!_slowMotionStartTime) {
      _slowMotionStartTime = time;
    } else {
      time = (time - _slowMotionStartTime) / f + _slowMotionStartTime;
      _slowMotionLastTime = time;
    }
  } else if (_slowMotionStartTime) {
    CFTimeInterval dt = (_slowMotionLastTime - time);
    time += dt;
    _slowMotionAccumulator += dt;
    _slowMotionStartTime = 0;
  }
#endif

  return time;
}

- (void)render
{
    pthread_mutex_lock(&_lock);
    BOOL paused = (0 == self->_observers.count && self->_list.empty()) || self->_disableDisplayLink;
    pthread_mutex_unlock(&_lock);
    
    if ( paused )
        return;
    
  CFTimeInterval time = [self _currentRenderTime];
  [self renderTime:time];
}

- (void)renderTime:(CFTimeInterval)time
{
  [self _renderTime:time items:_list];
}

- (void)addObserver:(id<POPAnimatorObserving>)observer
{
  NSAssert(nil != observer, @"attempting to add nil %@ observer", self);
  if (nil == observer) {
    return;
  }

  // lock
  pthread_mutex_lock(&_lock);

  if (!_observers) {
    // use ordered collection for deterministic callout
    _observers = [[NSMutableArray alloc] initWithCapacity:1];
  }

  [_observers addObject:observer];
  updateDisplayLink(self);

  // unlock
  pthread_mutex_unlock(&_lock);
}

- (void)removeObserver:(id<POPAnimatorObserving>)observer
{
  NSAssert(nil != observer, @"attempting to remove nil %@ observer", self);
  if (nil == observer) {
    return;
  }

  // lock
  pthread_mutex_lock(&_lock);

  [_observers removeObject:observer];
  updateDisplayLink(self);

  // unlock
  pthread_mutex_unlock(&_lock);
}

@end
