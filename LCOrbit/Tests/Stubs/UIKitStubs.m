// Link-time stubs for the UIKit shim declared in Stubs/UIKit/UIKit.h.
// Harness targets must provide OBJC_CLASS_$_UIColor because LCOrbitStorage
// references it; the harnesses never call into the theme math itself.
#import "UIKit/UIKit.h"

@implementation UIColor
+ (UIColor *)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha {
    return [[UIColor alloc] init];
}
- (BOOL)getRed:(CGFloat *)red green:(CGFloat *)green blue:(CGFloat *)blue alpha:(CGFloat *)alpha {
    return NO;
}
@end
