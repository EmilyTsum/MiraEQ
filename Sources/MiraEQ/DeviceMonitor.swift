import Foundation
import CoreAudio

public protocol DeviceMonitorDelegate: AnyObject {
    func defaultOutputDeviceDidChange(to deviceID: AudioObjectID, isBuiltInSpeakers: Bool, name: String, uid: String)
}

public class DeviceMonitor {
    public weak var delegate: DeviceMonitorDelegate?
    
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    public init() {}
    
    public func startMonitoring() {
        stopMonitoring()

        // First, trigger delegate for current state
        if let currentID = getCurrentDefaultOutputDeviceID() {
            let info = Self.getDeviceInfo(deviceID: currentID)
            delegate?.defaultOutputDeviceDidChange(to: currentID, isBuiltInSpeakers: info.isSpeakers, name: info.name, uid: info.uid)
        }

        // Define listener block
        let block: AudioObjectPropertyListenerBlock = { [weak self] (numberAddresses, addresses) in
            guard let self = self else { return }
            if let currentID = self.getCurrentDefaultOutputDeviceID() {
                let info = Self.getDeviceInfo(deviceID: currentID)
                self.delegate?.defaultOutputDeviceDidChange(to: currentID, isBuiltInSpeakers: info.isSpeakers, name: info.name, uid: info.uid)
            }
        }
        
        self.listenerBlock = block
        
        // Pass .main to dispatch on the main thread for strict concurrency compliance
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            .main,
            block
        )
        if status != noErr {
            print("Error: Failed to register default output device listener: \(status)")
            self.listenerBlock = nil
        }
    }
    
    public func stopMonitoring() {
        guard let block = listenerBlock else { return }
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            .main,
            block
        )
        if status != noErr {
            print("Warning: Failed to remove default output device listener: \(status)")
        }
        listenerBlock = nil
    }
    
    public func getCurrentDefaultOutputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }
    
    public static func getDeviceInfo(deviceID: AudioObjectID) -> (name: String, uid: String, isSpeakers: Bool) {
        var name = "Unknown Device"
        var uid = ""
        var isSpeakers = false
        
        // 1. Get Name
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>? = nil
        var status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        if status == noErr, let cf = cfName {
            name = cf.takeRetainedValue() as String
        }
        
        // 2. Get UID
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        var cfUID: Unmanaged<CFString>? = nil
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID)
        if status == noErr, let cf = cfUID {
            uid = cf.takeRetainedValue() as String
        }
        
        // 3. Get Transport Type
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        var transportType = UInt32(0)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        
        let isBuiltIn = (status == noErr && transportType == kAudioDeviceTransportTypeBuiltIn)
        let nameLower = name.lowercased()
        let uidLower = uid.lowercased()
        
        // Match modern Apple Silicon speaker naming/UIDs
        let nameContainsSpeaker = nameLower.contains("speaker") || nameLower.contains("speakers")
        let uidContainsSpeaker = uidLower.contains("speaker")
        
        isSpeakers = isBuiltIn && (nameContainsSpeaker || uidContainsSpeaker)
        
        return (name, uid, isSpeakers)
    }
}
