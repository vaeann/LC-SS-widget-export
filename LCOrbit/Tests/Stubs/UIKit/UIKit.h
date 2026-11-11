// Test-only shim: guest/multitask/storage harnesses compile on the macOS SDK,
// where UIKit does not exist. No UIKit behavior is mocked or tested here.
#import <Foundation/Foundation.h>
@class UIWindowScene;

// Minimal UIColor surface: LCOrbitStorage's theme math names the type and
// its factory/getter messages. Harnesses compile against this stub only so
// the translation units link; the behavior itself is never exercised.
@interface UIColor : NSObject
+ (UIColor *)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha;
- (BOOL)getRed:(CGFloat *)red green:(CGFloat *)green blue:(CGFloat *)blue alpha:(CGFloat *)alpha;
@end
