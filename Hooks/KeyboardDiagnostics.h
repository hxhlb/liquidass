#pragma once

// Debug-only metadata. Never read input text or change keyboard rendering.
static const void *kLGKeyboardSceneSnapshotKey = &kLGKeyboardSceneSnapshotKey;
static NSUInteger gLGKeyboardSceneSnapshots;

static id LGKeyboardDiagnosticObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char *type = method_copyReturnType(method);
    BOOL supported = type && type[0] == '@';
    free(type);
    return supported ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static NSNumber *LGKeyboardDiagnosticNumber(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char *type = method_copyReturnType(method);
    NSNumber *value = nil;
    if (type) switch (type[0]) {
        case 'B': value = @(((bool (*)(id, SEL))objc_msgSend)(object, selector)); break;
        case 'c': value = @(((char (*)(id, SEL))objc_msgSend)(object, selector)); break;
        case 'i': value = @(((int (*)(id, SEL))objc_msgSend)(object, selector)); break;
        case 'q': value = @(((long long (*)(id, SEL))objc_msgSend)(object, selector)); break;
        case 'Q': value = @(((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector)); break;
        case 'f': value = @(((float (*)(id, SEL))objc_msgSend)(object, selector)); break;
        case 'd': value = @(((double (*)(id, SEL))objc_msgSend)(object, selector)); break;
    }
    free(type);
    return value;
}

static id LGKeyboardDiagnosticColor(UIColor *color, UITraitCollection *traits) {
    if (!color) return NSNull.null;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    return [[color resolvedColorWithTraitCollection:traits] getRed:&r green:&g blue:&b alpha:&a]
        ? @[@(r), @(g), @(b), @(a)] : color.description;
}

static NSArray *LGKeyboardDiagnosticFilters(CALayer *layer) {
    NSMutableArray *names = [NSMutableArray array];
    for (id filter in layer.filters) {
        id type = LGKeyboardDiagnosticObject(filter, @"type");
        [names addObject:[type isKindOfClass:NSString.class] ? type : NSStringFromClass([filter class])];
    }
    return names;
}

static NSDictionary *LGKeyboardDiagnosticView(UIView *view, UIWindow *window) {
    CALayer *layer = view.layer;
    id blend = layer.compositingFilter;
    if (blend && ![blend isKindOfClass:NSString.class])
        blend = LGKeyboardDiagnosticObject(blend, @"type") ?: NSStringFromClass([blend class]);
    return @{
        @"class": NSStringFromClass(view.class),
        @"parent": view.superview ? NSStringFromClass(view.superview.class) : @"",
        @"index": @(view.superview ? [view.superview.subviews indexOfObjectIdenticalTo:view] : 0),
        @"frame": NSStringFromCGRect([view convertRect:view.bounds toView:window]),
        @"bounds": NSStringFromCGRect(view.bounds),
        @"hidden": @(view.hidden), @"alpha": @(view.alpha),
        @"clips": @(view.clipsToBounds), @"viewOpaque": @(view.opaque),
        @"appearance": @(view.traitCollection.userInterfaceStyle),
        @"background": LGKeyboardDiagnosticColor(view.backgroundColor, view.traitCollection),
        @"layerClass": NSStringFromClass(layer.class), @"layerOpaque": @(layer.opaque),
        @"layerBackground": LGKeyboardDiagnosticColor(layer.backgroundColor
            ? [UIColor colorWithCGColor:layer.backgroundColor] : nil, view.traitCollection),
        @"filters": LGKeyboardDiagnosticFilters(layer), @"blend": blend ?: NSNull.null,
        @"hasContents": @(layer.contents != nil)
    };
}

static NSDictionary *LGKeyboardDiagnosticConfig(id config) {
    if (!config) return @{};
    NSMutableDictionary *values = [NSMutableDictionary dictionaryWithObject:NSStringFromClass([config class]) forKey:@"class"];
    for (NSString *key in @[@"lightKeyboard", @"backdropStyle", @"blurRadius", @"blurSaturation",
                             @"keycapOpacity", @"lightKeycapOpacity", @"forceQuality"]) {
        NSNumber *value = LGKeyboardDiagnosticNumber(config, key);
        if (value) values[key] = value;
    }
    return values;
}

static void LGKeyboardWriteSceneSnapshot(UIWindow *window, UIView *primary) {
    NSMutableDictionary *preferences = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"Renderer.Profile", @"Renderer.BlurMode", @"Keyboard.Blur",
                             @"Keyboard.LightTint", @"Keyboard.DarkTint", @"Keyboard.RefractionScale",
                             @"Keyboard.GlassThickness", @"Keyboard.BevelWidthPoints"]) {
        id value = LGGlassPreferenceValue(key);
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) preferences[key] = value;
    }
    id impl = LGKeyboardDiagnosticObject(NSClassFromString(@"UIKeyboardImpl"), @"activeInstance");
    id layout = LGKeyboardDiagnosticObject(impl, @"activeLayout");
    id traits = LGKeyboardDiagnosticObject(impl, @"textInputTraits");
    NSMutableDictionary *input = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"keyboardAppearance", @"keyboardType", @"secureTextEntry"]) {
        NSNumber *value = LGKeyboardDiagnosticNumber(traits, key);
        if (value) input[key] = value;
    }
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:window];
    NSMutableArray *views = [NSMutableArray array];
    CGRect area = [primary convertRect:primary.bounds toView:window];
    NSUInteger visited = 0;
    while (pending.count && visited++ < 400 && views.count < 80) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        [pending addObjectsFromArray:view.subviews];
        CGRect frame = [view convertRect:view.bounds toView:window];
        NSString *name = NSStringFromClass(view.class);
        BOOL relevantClass = [name containsString:@"Backdrop"] || [name containsString:@"SplitImage"] ||
            [name containsString:@"Keyplane"] || [name containsString:@"BlurView"];
        BOOL large = CGRectGetWidth(view.bounds) >= 150 && CGRectGetHeight(view.bounds) >= 80;
        if (!CGRectIntersectsRect(frame, area) || (!large && !relevantClass)) continue;
        NSMutableDictionary *row = [LGKeyboardDiagnosticView(view, window) mutableCopy];
        id config = LGKeyboardDiagnosticObject(view, @"renderConfig");
        if (config) row[@"config"] = LGKeyboardDiagnosticConfig(config);
        id factory = LGKeyboardDiagnosticObject(view, @"factory");
        id keyColor = LGKeyboardDiagnosticObject(factory, @"defaultKeyBackgroundColorName");
        if ([keyColor isKindOfClass:NSString.class]) row[@"keyBackgroundName"] = keyColor;
        NSNumber *blur = LGKeyboardDiagnosticNumber(view, @"blurRadius");
        if (blur) row[@"blurRadius"] = blur;
        NSNumber *attached = LGKeyboardDiagnosticNumber(view, @"lgFilterAttached");
        if (attached) row[@"filterAttached"] = attached;
        [views addObject:row];
    }
    NSDictionary *report = @{
        @"version": @53, @"app": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"window": NSStringFromClass(window.class), @"preferences": preferences,
        @"inputTraits": input,
        @"config": LGKeyboardDiagnosticConfig(LGKeyboardDiagnosticObject(layout, @"renderConfig")),
        @"primary": LGKeyboardDiagnosticView(primary, window), @"views": views,
        @"truncated": @(pending.count != 0)
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    if (data) LGLog(@"[keyboard-scene] %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}

static UIView *LGKeyboardDiagnosticPrimary(UIWindow *window) {
    Class backdropClass = NSClassFromString(@"UIKBBackdropView");
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:window];
    UIView *primary = nil;
    NSUInteger visited = 0;
    while (pending.count && visited++ < 400) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        [pending addObjectsFromArray:view.subviews];
        if (backdropClass && [view isKindOfClass:backdropClass] &&
            CGRectGetHeight(view.bounds) > CGRectGetHeight(primary.bounds)) primary = view;
    }
    return primary;
}

static void LGKeyboardScheduleSceneSnapshot(UIWindow *window) {
    if (!LGDebugLoggingEnabled() || !window || gLGKeyboardSceneSnapshots >= 8 ||
        objc_getAssociatedObject(window, kLGKeyboardSceneSnapshotKey)) return;
    objc_setAssociatedObject(window, kLGKeyboardSceneSnapshotKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIWindow *weakWindow = window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *live = weakWindow;
        if (!live) return;
        objc_setAssociatedObject(live, kLGKeyboardSceneSnapshotKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (!LGDebugLoggingEnabled() || !lgHostEnabled(@"Keyboard") ||
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            gLGKeyboardSceneSnapshots >= 8) return;
        UIView *primary = LGKeyboardDiagnosticPrimary(live);
        if (!primary || CGRectGetHeight(primary.bounds) < 100) return;
        objc_setAssociatedObject(live, kLGKeyboardSceneSnapshotKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gLGKeyboardSceneSnapshots++;
        LGKeyboardWriteSceneSnapshot(live, primary);
    });
}
