// Read-only Frida snapshot. No Interceptor, setters, restart or process spawning.
// Attach only after the device/process has been confirmed by the user.
'use strict';

function value(object, selector) {
    try {
        if (!object || !object.handle || object.handle.isNull()) return null;
        if (typeof object[selector] !== 'function') return null;
        const result = object[selector]();
        if (result === null || result === undefined) return null;
        if (result.handle && result.handle.isNull()) return null;
        return result;
    } catch (error) { return { error: String(error) }; }
}

function description(object) {
    if (object === null || object === undefined) return null;
    try { return object.toString(); } catch (_) { return null; }
}

function style(object) {
    return description(value(value(object, 'traitCollection'), 'userInterfaceStyle'));
}

function viewInfo(view) {
    if (!view || !view.handle || view.handle.isNull()) return null;
    const window = value(view, 'window');
    const screen = value(window, 'screen');
    return {
        className: view.$className,
        address: view.handle.toString(),
        frame: description(value(view, 'frame')),
        windowClass: window && window.$className || null,
        viewStyle: style(view), windowStyle: style(window), screenStyle: style(screen),
        overrideStyle: description(value(view, 'overrideUserInterfaceStyle'))
    };
}

function providerInfo(provider) {
    if (!provider || !provider.handle || provider.handle.isNull()) return null;
    const result = { className: provider.$className, address: provider.handle.toString() };
    for (const key of ['primaryColor', 'secondaryColor', 'tertiaryColor',
                       'quaternaryColor', 'separatorColor', 'supportsVibrancy']) {
        result[key] = description(value(provider, key));
    }
    return result;
}

function methodInfo(className, selector) {
    const klass = ObjC.classes[className];
    if (!klass || !klass[selector]) return null;
    const implementation = klass[selector].implementation.strip();
    const image = Process.findModuleByAddress(implementation);
    return { implementation: implementation.toString(),
             module: image ? image.name : null,
             offset: image ? implementation.sub(image.base).toString() : null };
}

function instances(className, reader) {
    const klass = ObjC.classes[className];
    if (!klass) return { classPresent: false };
    try {
        const objects = ObjC.chooseSync(klass);
        return { classPresent: true, count: objects.length,
                 samples: objects.slice(0, 8).map(reader) };
    } catch (error) { return { classPresent: true, error: String(error) }; }
}

if (!ObjC.available) {
    send({ error: 'Objective-C runtime unavailable' });
} else {
    ObjC.schedule(ObjC.mainQueue, function () {
        const report = {
            process: Process.id,
            bundle: description(ObjC.classes.NSBundle.mainBundle().bundleIdentifier()),
            os: description(ObjC.classes.UIDevice.currentDevice().systemVersion()),
            screenStyle: style(ObjC.classes.UIScreen.mainScreen()),
            tweakModules: Process.enumerateModules().filter(m => /liquidass/i.test(m.name))
                .map(m => ({ name: m.name, path: m.path })),
            methods: {}
        };
        for (const [klass, selector] of [
            ['SBUISystemApertureElementSource', '- _updateTraitCollectionForElementIfNeeded'],
            ['MRUActivityNowPlayingView', '- layoutSubviews'],
            ['MRUActivityNowPlayingView', '- setStylingProvider:'],
            ['SBSystemApertureContainerView', '- layoutSubviews'],
            ['SBSystemApertureSceneElement', '- _updateMutableSceneSettings:withParameters:'],
            ['UIWindow', '- traitCollectionDidChange:']
        ]) report.methods[klass + ' ' + selector] = methodInfo(klass, selector);
        report.musicViews = instances('MRUActivityNowPlayingView', view => ({
            ...viewInfo(view), provider: providerInfo(value(view, 'stylingProvider'))
        }));
        report.islandContainers = instances('SBSystemApertureContainerView', viewInfo);
        report.hostedElements = instances('SBSystemApertureSceneElement', element => {
            const scene = value(element, 'scene');
            const settings = value(element, 'sceneSettings');
            return {
                client: description(value(element, 'clientIdentifier')),
                active: description(value(element, 'isActivated')),
                settingsClass: settings && settings.$className || null,
                sceneClass: scene && scene.$className || null,
                canUpdateSettings: scene ? !!scene.respondsToSelector_(ObjC.selector('updateSettingsWithBlock:')) : false,
                style: description(value(settings, 'userInterfaceStyle')),
                sceneSettingsStyle: description(value(value(scene, 'settings'), 'userInterfaceStyle'))
            };
        });
        report.mediaStates = instances('LGIslandMediaState', state => ({
            applying: description(value(state, 'applying')),
            nativeProvider: providerInfo(value(state, 'nativeProvider')),
            lightProvider: providerInfo(value(state, 'lightProvider'))
        }));
        report.contentStates = instances('LGIslandContentState', state => ({
            appliedStyle: description(value(state, 'appliedStyle')),
            view: value(state, 'view') ? viewInfo(value(state, 'view')) : null
        }));
        send(report);
    });
}
