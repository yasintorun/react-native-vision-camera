//
//  FrameProcessorRuntimeManager.m
//  VisionCamera
//
//  Created by Marc Rousavy on 23.03.21.
//  Copyright © 2021 mrousavy. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "FrameProcessorRuntimeManager.h"
#import "FrameProcessorPluginRegistry.h"
#import "FrameHostObject.h"

#import <memory>

#import <React/RCTBridge.h>
#import <ReactCommon/RCTTurboModule.h>
#import <React/RCTBridge+Private.h>
#import <React/RCTUIManager.h>
#import <ReactCommon/RCTTurboModuleManager.h>

#import "JsiWorkletContext.h"
#import "JsiWorkletApi.h"
#import "JsiWorklet.h"

#import "FrameProcessorUtils.h"
#import "FrameProcessorCallback.h"
#import "../React Utils/MakeJSIRuntime.h"
#import "../React Utils/JSIUtils.h"

// Forward declarations for the Swift classes
__attribute__((objc_runtime_name("_TtC12VisionCamera12CameraQueues")))
@interface CameraQueues : NSObject
@property (nonatomic, class, readonly, strong) dispatch_queue_t _Nonnull frameProcessorQueue;
@end
__attribute__((objc_runtime_name("_TtC12VisionCamera10CameraView")))
@interface CameraView : UIView
@property (nonatomic, copy) FrameProcessorCallback _Nullable frameProcessorCallback;
@end

@implementation FrameProcessorRuntimeManager {
  __weak RCTBridge* weakBridge;
  std::shared_ptr<RNWorklet::JsiWorkletContext> workletContext;
}

- (instancetype) initWithBridge:(RCTBridge*)bridge {
  self = [super init];
  if (self) {
    // init self idk
  }
  return self;
}

- (void) setupWorkletContext:(jsi::Runtime&)runtime {
  NSLog(@"FrameProcessorBindings: Creating Worklet Context...");

  auto callInvoker = RCTBridge.currentBridge.jsCallInvoker;
  
  auto runOnJS = [callInvoker](std::function<void()>&& f) {
    // Run on React JS Runtime
    callInvoker->invokeAsync(std::move(f));
  };
  auto runOnWorklet = [](std::function<void()>&& f) {
    // Run on Frame Processor Worklet Runtime
    dispatch_async(CameraQueues.frameProcessorQueue, ^{
      f();
    });
  };
  
  workletContext = std::make_shared<RNWorklet::JsiWorkletContext>("VisionCamera");
  workletContext->initialize("VisionCamera",
                             &runtime,
                             runOnJS,
                             runOnWorklet);
  RNWorklet::JsiWorkletApi::installApi(runtime);

  NSLog(@"FrameProcessorBindings: Worklet Context Created!");
  
  workletContext->invokeOnWorkletThread([=]() {
    auto& workletRuntime = workletContext->getWorkletRuntime();
    
    workletRuntime.global().setProperty(workletRuntime, "_FRAME_PROCESSOR", jsi::Value(true));
    
    // Install Skia
    /*jsi::Runtime* rrr = &workletRuntime;
    auto platformContext = std::make_shared<RNSkia::RNSkiOSPlatformContext>(rrr, callInvoker);
    auto skiaApi = std::make_shared<RNSkia::JsiSkApi>(workletRuntime, platformContext);
    workletRuntime.global().setProperty(workletRuntime,
                                        "SkiaApi",
                                        jsi::Object::createFromHostObject(workletRuntime, std::move(skiaApi)));*/
  });
}

- (void) installFrameProcessorBindings {
#ifdef ENABLE_FRAME_PROCESSORS
  if (!weakBridge) {
    NSLog(@"FrameProcessorBindings: Failed to install Frame Processor Bindings - bridge was null!");
    return;
  }

  NSLog(@"FrameProcessorBindings: Installing Frame Processor Bindings for Bridge...");
  RCTCxxBridge *cxxBridge = (RCTCxxBridge *)weakBridge;
  if (!cxxBridge.runtime) {
    return;
  }

  jsi::Runtime& jsiRuntime = *(jsi::Runtime*)cxxBridge.runtime;
  
  // Install the Worklet Runtime in the main React JS Runtime
  [self setupWorkletContext:jsiRuntime];
  
  NSLog(@"FrameProcessorBindings: Installing global functions...");

  // setFrameProcessor(viewTag: number, frameProcessor: (frame: Frame) => void)
  auto setFrameProcessor = [self](jsi::Runtime& runtime,
                                  const jsi::Value& thisValue,
                                  const jsi::Value* arguments,
                                  size_t count) -> jsi::Value {
    NSLog(@"FrameProcessorBindings: Setting new frame processor...");
    if (!arguments[0].isNumber()) throw jsi::JSError(runtime, "Camera::setFrameProcessor: First argument ('viewTag') must be a number!");
    if (!arguments[1].isObject()) throw jsi::JSError(runtime, "Camera::setFrameProcessor: Second argument ('frameProcessor') must be a function!");
    if (!runtimeManager || !runtimeManager->runtime) throw jsi::JSError(runtime, "Camera::setFrameProcessor: The RuntimeManager is not yet initialized!");

    auto viewTag = arguments[0].asNumber();
    NSLog(@"FrameProcessorBindings: Converting JSI Function to Worklet...");
    auto worklet = std::make_shared<RNWorklet::JsiWorklet>(runtime, arguments[1]);

    RCTExecuteOnMainQueue([=]() {
      auto currentBridge = [RCTBridge currentBridge];
      auto anonymousView = [currentBridge.uiManager viewForReactTag:[NSNumber numberWithDouble:viewTag]];
      auto view = static_cast<CameraView*>(anonymousView);
      
      NSLog(@"FrameProcessorBindings: Converting worklet to Objective-C callback...");
      
      view.frameProcessorCallback = convertWorkletToFrameProcessorCallback(rt, worklet);
      
      NSLog(@"FrameProcessorBindings: Frame processor set!");
    });

    return jsi::Value::undefined();
  };
  jsiRuntime.global().setProperty(jsiRuntime, "setFrameProcessor", jsi::Function::createFromHostFunction(jsiRuntime,
                                                                                                         jsi::PropNameID::forAscii(jsiRuntime, "setFrameProcessor"),
                                                                                                         2,  // viewTag, frameProcessor
                                                                                                         setFrameProcessor));

  // unsetFrameProcessor(viewTag: number)
  auto unsetFrameProcessor = [](jsi::Runtime& runtime,
                                const jsi::Value& thisValue,
                                const jsi::Value* arguments,
                                size_t count) -> jsi::Value {
    NSLog(@"FrameProcessorBindings: Removing frame processor...");
    if (!arguments[0].isNumber()) throw jsi::JSError(runtime, "Camera::unsetFrameProcessor: First argument ('viewTag') must be a number!");
    auto viewTag = arguments[0].asNumber();

    RCTExecuteOnMainQueue(^{
      auto currentBridge = [RCTBridge currentBridge];
      if (!currentBridge) return;

      auto anonymousView = [currentBridge.uiManager viewForReactTag:[NSNumber numberWithDouble:viewTag]];
      if (!anonymousView) return;

      auto view = static_cast<CameraView*>(anonymousView);
      view.frameProcessorCallback = nil;
      NSLog(@"FrameProcessorBindings: Frame processor removed!");
    });

    return jsi::Value::undefined();
  };
  jsiRuntime.global().setProperty(jsiRuntime, "unsetFrameProcessor", jsi::Function::createFromHostFunction(jsiRuntime,
                                                                                                           jsi::PropNameID::forAscii(jsiRuntime, "unsetFrameProcessor"),
                                                                                                           1,  // viewTag
                                                                                                           unsetFrameProcessor));

  NSLog(@"FrameProcessorBindings: Finished installing bindings.");
#endif
}

@end
