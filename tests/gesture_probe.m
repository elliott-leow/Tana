#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <math.h>
#include <unistd.h>
// Controlled integration-test input. Run only with Tana active.
int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr,"usage: gesture_probe swipe <progress> | vertical <progress> | vertical-begin/change/end/cancel <progress> | resize <points> | key <keycode>\n"); return 2; }
    double value = strtod(argv[2],NULL);
    if (!isfinite(value)) return 2;
    if (!strncmp(argv[1],"vertical-",9)) {
        const char *part=argv[1]+9;
        int phase=!strcmp(part,"begin")?1:!strcmp(part,"change")?2:!strcmp(part,"end")?4:!strcmp(part,"cancel")?8:0;
        if(!phase) return 2;
        CGEventRef e=CGEventCreate(NULL);
        CGEventSetType(e,(CGEventType)30);
        CGEventSetIntegerValueField(e,(CGEventField)110,23);
        CGEventSetIntegerValueField(e,(CGEventField)123,2);
        CGEventSetIntegerValueField(e,(CGEventField)132,phase);
        CGEventSetDoubleValueField(e,(CGEventField)124,value);
        CGEventPost(kCGHIDEventTap,e); CFRelease(e);
    } else if (!strcmp(argv[1],"swipe") || !strcmp(argv[1],"vertical")) {
        for (int i=0;i<=31;++i) {
            CGEventRef e = CGEventCreate(NULL);
            CGEventSetType(e,(CGEventType)30);
            CGEventSetIntegerValueField(e,(CGEventField)110,23);
            CGEventSetIntegerValueField(e,(CGEventField)123,!strcmp(argv[1],"vertical")?2:1);
            CGEventSetIntegerValueField(e,(CGEventField)132,i==0?1:(i==31?4:2));
            CGEventSetDoubleValueField(e,(CGEventField)124,value*fmin(i,30)/30.0);
            CGEventPost(kCGHIDEventTap,e); CFRelease(e); usleep(8333);
        }
    } else if (!strcmp(argv[1],"resize")) {
        CGEventRef e = CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitPixel,2,(int)value,0);
        CGEventSetFlags(e,kCGEventFlagMaskAlternate);
        CGEventPost(kCGHIDEventTap,e); CFRelease(e);
    } else if (!strcmp(argv[1],"key")) {
        CGEventRef e = CGEventCreateKeyboardEvent(NULL,(CGKeyCode)value,true);
        CGEventSetFlags(e,kCGEventFlagMaskAlternate|kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap,e); CFRelease(e); usleep(30000);
        e=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)value,false);
        CGEventSetFlags(e,kCGEventFlagMaskAlternate|kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap,e); CFRelease(e);
    } else return 2;
    return 0;
}
