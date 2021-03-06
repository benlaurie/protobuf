// Protocol Buffers - Google's data interchange format
// Copyright 2008 Google Inc.  All rights reserved.
// https://developers.google.com/protocol-buffers/
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import "GPBRootObject_PackagePrivate.h"

#import <objc/runtime.h>

#import <CoreFoundation/CoreFoundation.h>

#import "GPBDescriptor.h"
#import "GPBExtensionField.h"
#import "GPBUtilities_PackagePrivate.h"

@interface GPBExtensionDescriptor (GPBRootObject)
// Get singletonName as a c string.
- (const char *)singletonNameC;
@end

@implementation GPBRootObject

// Taken from http://www.burtleburtle.net/bob/hash/doobs.html
// Public Domain
static uint32_t jenkins_one_at_a_time_hash(const char *key) {
  uint32_t hash = 0;
  for (uint32_t i = 0; key[i] != '\0'; ++i) {
    hash += key[i];
    hash += (hash << 10);
    hash ^= (hash >> 6);
  }
  hash += (hash << 3);
  hash ^= (hash >> 11);
  hash += (hash << 15);
  return hash;
}

// Key methods for our custom CFDictionary.
// Note that the dictionary lasts for the lifetime of our app, so no need
// to worry about deallocation. All of the items are added to it at
// startup, and so the keys don't need to be retained/released.
// Keys are NULL terminated char *.
static const void *GPBRootExtensionKeyRetain(CFAllocatorRef allocator,
                                             const void *value) {
#pragma unused(allocator)
  return value;
}

static void GPBRootExtensionKeyRelease(CFAllocatorRef allocator,
                                       const void *value) {
#pragma unused(allocator)
#pragma unused(value)
}

static CFStringRef GPBRootExtensionCopyKeyDescription(const void *value) {
  const char *key = (const char *)value;
  return CFStringCreateWithCString(kCFAllocatorDefault, key,
                                   kCFStringEncodingUTF8);
}

static Boolean GPBRootExtensionKeyEqual(const void *value1,
                                        const void *value2) {
  const char *key1 = (const char *)value1;
  const char *key2 = (const char *)value2;
  return strcmp(key1, key2) == 0;
}

static CFHashCode GPBRootExtensionKeyHash(const void *value) {
  const char *key = (const char *)value;
  return jenkins_one_at_a_time_hash(key);
}

static CFMutableDictionaryRef gExtensionSingletonDictionary = NULL;

+ (void)initialize {
  if (!gExtensionSingletonDictionary) {
    CFDictionaryKeyCallBacks keyCallBacks = {
      // See description above for reason for using custom dictionary.
      0,
      GPBRootExtensionKeyRetain,
      GPBRootExtensionKeyRelease,
      GPBRootExtensionCopyKeyDescription,
      GPBRootExtensionKeyEqual,
      GPBRootExtensionKeyHash,
    };
    gExtensionSingletonDictionary =
        CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &keyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
  }
}

+ (GPBExtensionRegistry *)extensionRegistry {
  // Is overridden in all the subclasses that provide extensions to provide the
  // per class one.
  return nil;
}

+ (void)globallyRegisterExtension:(GPBExtensionField *)field {
  const char *key = [field.descriptor singletonNameC];
  // Register happens at startup, so there is no thread safety issue in
  // modifying the dictionary.
  CFDictionarySetValue(gExtensionSingletonDictionary, key, field);
}

static id ExtensionForName(id self, SEL _cmd) {
  // Really fast way of doing "classname_selName".
  // This came up as a hotspot (creation of NSString *) when accessing a
  // lot of extensions.
  const char *className = class_getName(self);
  const char *selName = sel_getName(_cmd);
  size_t classNameLen = strlen(className);
  size_t selNameLen = strlen(selName);
  char key[classNameLen + selNameLen + 2];
  memcpy(key, className, classNameLen);
  key[classNameLen] = '_';
  memcpy(&key[classNameLen + 1], selName, selNameLen);
  key[classNameLen + 1 + selNameLen] = '\0';
  id extension = (id)CFDictionaryGetValue(gExtensionSingletonDictionary, key);
  // We can't remove the key from the dictionary here (as an optimization),
  // because resolveClassMethod can happen on any thread and we'd then need
  // a lock.
  return extension;
}

+ (BOOL)resolveClassMethod:(SEL)sel {
  // Another option would be to register the extensions with the class at
  // globallyRegisterExtension:
  // Timing the two solutions, this solution turned out to be much faster
  // and reduced startup time, and runtime memory.
  // On an iPhone 5s:
  // ResolveClassMethod: 1515583 nanos
  // globallyRegisterExtension: 2453083 nanos
  // The advantage to globallyRegisterExtension is that it would reduce the
  // size of the protos somewhat because the singletonNameC wouldn't need
  // to include the class name. For a class with a lot of extensions it
  // can add up. You could also significantly reduce the code complexity of this
  // file.
  id extension = ExtensionForName(self, sel);
  if (extension != nil) {
    const char *encoding =
        GPBMessageEncodingForSelector(@selector(getClassValue), NO);
    Class metaClass = objc_getMetaClass(class_getName(self));
    IMP imp = imp_implementationWithBlock(^(id obj) {
#pragma unused(obj)
      return extension;
    });
    return class_addMethod(metaClass, sel, imp, encoding);
  }
  return [super resolveClassMethod:sel];
}

@end
