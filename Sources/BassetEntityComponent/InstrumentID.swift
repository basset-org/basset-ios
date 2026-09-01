public enum InstrumentID: UInt16, Sendable, CaseIterable {
    case memoryFootprint = 1
    case deviceInfo = 2
    case thermalState = 3
    case cameraSessionState = 4
    case viewControllerAppear = 5
    case viewLayoutPass = 6
    case urlSessionTaskMetrics = 7
    case networkPathTransitions = 8
    case appStateChanges = 9
    case cameraDeviceInventory = 10
    case cameraSessionConfiguration = 11
    case cameraDeviceFormat = 12
    case cameraFrameDelivery = 13
    case mainThreadHang = 14
    case threadSnapshot = 15
    case swiftUIRuntimeIssues = 16
    case swiftUIHostAppear = 17
    case swiftUIHostUpdates = 18
    case swiftUIPresentation = 19
    case swiftUIDisplayListChurn = 20
    case memoryPressure = 21
    case permissionStatus = 23
    case permissionChanges = 24
    case lastRunEnded = 25
    case threadInventory = 26
    case queueLatency = 27
    case cpuThreadUsage = 28
    case cpuWakeups = 29
    case coreDataSave = 30
    case coreDataChanges = 31
    case logFaults = 32
    case logSubsystems = 33
    case sessionConfiguration = 34
    case transportSecurity = 35
    case framePacing = 36
    case accessibilitySettings = 37
    case dynamicType = 38
    case localeSettings = 39
    case notificationSettings = 42
    case locationSilence = 43
    case bluetoothCentralState = 44
    case webContentTermination = 45
    case mapTileLoading = 46
    case callProviderActions = 47
    case audioRoute = 48
    case stackSamples = 49
    case metalDrawablePresentation = 50
    case metalGPULatency = 51
    case linkedLibraries = 52
    case methodOwners = 53
    case windowTouches = 54
    case controlAction = 55
    case gestureState = 56
    case viewHierarchy = 57
    case imagingRenderPasses = 58
    case configRefused = 0xff00
    case instrumentsActive = 0xff01
    case instrumentsRelevant = 0xff02

    public var name: String {
        switch self {
        case .memoryFootprint: "memory.footprint"
        case .deviceInfo: "device.info"
        case .thermalState: "power.thermalState"
        case .cameraSessionState: "camera.session.state"
        case .viewControllerAppear: "uikit.viewController.appear"
        case .viewLayoutPass: "uikit.view.layoutPass"
        case .urlSessionTaskMetrics: "network.urlSession.taskMetrics"
        case .networkPathTransitions: "network.path.transitions"
        case .appStateChanges: "lifecycle.app.state"
        case .cameraDeviceInventory: "camera.device.inventory"
        case .cameraSessionConfiguration: "camera.session.configuration"
        case .cameraDeviceFormat: "camera.device.format"
        case .cameraFrameDelivery: "camera.frames.delivery"
        case .mainThreadHang: "concurrency.mainThreadHang"
        case .threadSnapshot: "runtime.threadSnapshot"
        case .swiftUIRuntimeIssues: "swiftui.runtimeIssues"
        case .swiftUIHostAppear: "swiftui.host.appear"
        case .swiftUIHostUpdates: "swiftui.host.updates"
        case .swiftUIPresentation: "swiftui.presentation"
        case .swiftUIDisplayListChurn: "swiftui.displayList.churn"
        case .memoryPressure: "memory.pressure"
        case .permissionStatus: "permissions.status"
        case .permissionChanges: "permissions.changes"
        case .lastRunEnded: "lifecycle.lastRunEnded"
        case .threadInventory: "concurrency.thread.inventory"
        case .queueLatency: "concurrency.queue.latency"
        case .cpuThreadUsage: "cpu.thread.usage"
        case .cpuWakeups: "cpu.wakeups"
        case .coreDataSave: "storage.coreData.save"
        case .coreDataChanges: "storage.coreData.changes"
        case .logFaults: "log.faults"
        case .logSubsystems: "log.subsystems"
        case .sessionConfiguration: "network.session.configuration"
        case .transportSecurity: "network.transportSecurity"
        case .framePacing: "render.frame.pacing"
        case .accessibilitySettings: "environment.accessibility"
        case .dynamicType: "environment.dynamicType"
        case .localeSettings: "environment.locale"
        case .notificationSettings: "notifications.settings"
        case .locationSilence: "location.delegate.silence"
        case .bluetoothCentralState: "bluetooth.central.state"
        case .webContentTermination: "webkit.contentProcess.termination"
        case .mapTileLoading: "map.tile.loading"
        case .callProviderActions: "call.provider.actions"
        case .audioRoute: "audio.route"
        case .stackSamples: "runtime.stackSamples"
        case .imagingRenderPasses: "imaging.render.passes"
        case .metalDrawablePresentation: "metal.drawable.presentation"
        case .metalGPULatency: "metal.gpu.latency"
        case .linkedLibraries: "runtime.linkedLibraries"
        case .methodOwners: "runtime.methodOwners"
        case .windowTouches: "uikit.window.touches"
        case .controlAction: "uikit.control.action"
        case .gestureState: "uikit.gesture.state"
        case .viewHierarchy: "uikit.view.hierarchy"
        case .configRefused: "basset.configRefused"
        case .instrumentsActive: "basset.instrumentsActive"
        case .instrumentsRelevant: "basset.instrumentsRelevant"
        }
    }

    public var domain: Domain {
        switch self {
        case .memoryFootprint: .memory
        case .deviceInfo: .device
        case .thermalState: .power
        case .cameraSessionState: .camera
        case .viewControllerAppear: .uikit
        case .viewLayoutPass: .uikit
        case .urlSessionTaskMetrics: .network
        case .networkPathTransitions: .network
        case .appStateChanges: .lifecycle
        case .cameraDeviceInventory: .camera
        case .cameraSessionConfiguration: .camera
        case .cameraDeviceFormat: .camera
        case .cameraFrameDelivery: .camera
        case .mainThreadHang: .concurrency
        case .threadSnapshot: .runtime
        case .swiftUIRuntimeIssues: .swiftui
        case .swiftUIHostAppear: .swiftui
        case .swiftUIHostUpdates: .swiftui
        case .swiftUIPresentation: .swiftui
        case .swiftUIDisplayListChurn: .swiftui
        case .memoryPressure: .memory
        case .permissionStatus: .permissions
        case .permissionChanges: .permissions
        case .lastRunEnded: .lifecycle
        case .threadInventory: .concurrency
        case .queueLatency: .concurrency
        case .cpuThreadUsage: .cpu
        case .cpuWakeups: .cpu
        case .coreDataSave: .storage
        case .coreDataChanges: .storage
        case .logFaults: .log
        case .logSubsystems: .log
        case .sessionConfiguration: .network
        case .transportSecurity: .network
        case .framePacing: .render
        case .accessibilitySettings: .environment
        case .dynamicType: .environment
        case .localeSettings: .environment
        case .notificationSettings: .notifications
        case .locationSilence: .location
        case .bluetoothCentralState: .bluetooth
        case .webContentTermination: .webkit
        case .mapTileLoading: .map
        case .callProviderActions: .call
        case .audioRoute: .audio
        case .stackSamples: .runtime
        case .imagingRenderPasses: .imaging
        case .metalDrawablePresentation: .metal
        case .metalGPULatency: .metal
        case .linkedLibraries: .runtime
        case .methodOwners: .runtime
        case .windowTouches: .uikit
        case .controlAction: .uikit
        case .gestureState: .uikit
        case .viewHierarchy: .uikit
        case .configRefused: .basset
        case .instrumentsActive: .basset
        case .instrumentsRelevant: .basset
        }
    }

    /// What `Registration` proves at compile time, readable here without compiling an instrument.
    public var delivery: Delivery {
        switch self {
        case .memoryFootprint: .stream
        case .deviceInfo: .reading
        case .thermalState: .stream
        case .cameraSessionState: .stream
        case .viewControllerAppear: .stream
        case .viewLayoutPass: .stream
        case .urlSessionTaskMetrics: .stream
        case .networkPathTransitions: .stream
        case .appStateChanges: .stream
        case .cameraDeviceInventory: .stream
        case .cameraSessionConfiguration: .stream
        case .cameraDeviceFormat: .stream
        case .cameraFrameDelivery: .stream
        case .mainThreadHang: .stream
        case .threadSnapshot: .fault
        case .swiftUIRuntimeIssues: .stream
        case .swiftUIHostAppear: .stream
        case .swiftUIHostUpdates: .stream
        case .swiftUIPresentation: .stream
        case .swiftUIDisplayListChurn: .stream
        case .memoryPressure: .stream
        case .permissionStatus: .reading
        case .permissionChanges: .stream
        case .lastRunEnded: .stream
        case .threadInventory: .reading
        case .queueLatency: .stream
        case .cpuThreadUsage: .stream
        case .cpuWakeups: .stream
        case .coreDataSave: .stream
        case .coreDataChanges: .stream
        case .logFaults: .stream
        case .logSubsystems: .stream
        case .sessionConfiguration: .stream
        case .transportSecurity: .reading
        case .framePacing: .stream
        case .accessibilitySettings: .stream
        case .dynamicType: .stream
        case .localeSettings: .reading
        case .notificationSettings: .stream
        case .locationSilence: .stream
        case .bluetoothCentralState: .stream
        case .webContentTermination: .stream
        case .mapTileLoading: .stream
        case .callProviderActions: .stream
        case .audioRoute: .stream
        case .stackSamples: .stream
        case .imagingRenderPasses: .stream
        case .metalDrawablePresentation: .stream
        case .metalGPULatency: .stream
        case .linkedLibraries: .reading
        case .methodOwners: .reading
        case .windowTouches: .stream
        case .controlAction: .stream
        case .gestureState: .stream
        case .viewHierarchy: .reading
        // Never activated: basset emits this itself, outside the registration table.
        case .configRefused: .reading
        case .instrumentsActive: .reading
        case .instrumentsRelevant: .reading
        }
    }

    /// Stated only where it differs from the floor every instrument shares.
    public var availability: Availability {
        switch self {
        case .cameraDeviceFormat,
             .cameraDeviceInventory,
             .cameraFrameDelivery,
             .cameraSessionConfiguration,
             .cameraSessionState:
            .init(simulator: false)
        // A simulator has no receiver or speaker; it reports whatever output device the Mac uses.
        case .audioRoute:
            .init(simulator: false)
        case .framePacing:
            .init(minIOS: 18)
        // A simulator draws through the Mac's own GPU onto the Mac's own display.
        case .metalDrawablePresentation,
             .metalGPULatency:
            .init(simulator: false)
        default:
            .init()
        }
    }
}
