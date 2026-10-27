#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

static BOOL isTestProcess(void) {
    const char *name = getprogname();
    return strcmp(name, "swiftpm-testing-helper") == 0 || strcmp(name, "xctest") == 0 || strstr(name, "Tests") != NULL;
}

static NSString *runTemporaryDirectory(void) {
    const char *directory = getenv("JRBAR_TEST_TMPDIR");
    if (!directory || !isTestProcess()) return NSTemporaryDirectory();
    return [NSString stringWithUTF8String:directory];
}
static NSURL *runTemporaryURL(id self, SEL command) {
    return [NSURL fileURLWithPath:runTemporaryDirectory() isDirectory:YES];
}
__attribute__((constructor)) static void useRunDirectory(void) {
    if (!getenv("JRBAR_TEST_TMPDIR") || !isTestProcess()) return;
    Method method = class_getInstanceMethod([NSFileManager class], @selector(temporaryDirectory));
    method_setImplementation(method, (IMP)runTemporaryURL);
}
__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} replaceTemporaryDirectory __attribute__((section("__DATA,__interpose"))) = {
    (const void *)runTemporaryDirectory, (const void *)NSTemporaryDirectory
};
