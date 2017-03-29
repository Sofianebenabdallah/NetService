#if os(OSX)
    import Darwin
#else
    import Glibc
    import CoreFoundation
#endif

import Foundation
import DNS


class UDPChannel {
    var received: ((_ address: SockAddr, _ data: Data, _ socket: CFSocket) -> ())?

    var socket4: (CFSocket, CFRunLoopSource)?
    var socket6: (CFSocket, CFRunLoopSource)?

    func schedule(in aRunLoop: RunLoop, forMode mode: RunLoopMode) {
        if let socket4 = socket4 {
            CFRunLoopAddSource(aRunLoop.getCFRunLoop(), socket4.1, .defaultMode)
        }
//        CFRunLoopAddSource(aRunLoop.getCFRunLoop(), runLoopSource6, .defaultMode)
    }

    func remove(from aRunLoop: RunLoop, forMode mode: RunLoopMode) {
        if let socket4 = socket4 {
            CFRunLoopRemoveSource(aRunLoop.getCFRunLoop(), socket4.1, .defaultMode)
        }
//        CFRunLoopRemoveSource(aRunLoop.getCFRunLoop(), runLoopSource6, .defaultMode)
    }

    init() throws {
        var yes: UInt32 = 1

        #if os(OSX)
            let fd4 = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #else
            let fd4 = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #endif
        guard fd4 >= 0 else {
            throw POSIXError()
        }

        var context = CFSocketContext()
        context.info = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // allow reuse
        try posix(setsockopt(fd4, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<UInt32>.size)))
        try posix(setsockopt(fd4, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<UInt32>.size)))

        // bind to IPv4 interface
        var ipv4 = sockaddr_in()
        ipv4.sin_family = sa_family_t(AF_INET)
        ipv4.sin_addr = in_addr(s_addr: UInt32(bigEndian: INADDR_ANY))
        ipv4.sin_port = (5353 as in_port_t).bigEndian

        try ipv4.withSockAddr {
            try posix(bind(fd4, $0, $1))
        }

        // subscribe to IPv4 mDNS multicast
        let group4 = IPv4("224.0.0.251")!
        var mreq4 = ip_mreq(imr_multiaddr: group4.address,
                            imr_interface: in_addr(s_addr: UInt32(bigEndian: INADDR_ANY)))
        #if os(OSX)
            try posix(setsockopt(fd4, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq4, socklen_t(MemoryLayout<ip_mreq>.size)))
        #else
            try posix(setsockopt(fd4, Int32(IPPROTO_IP), Int32(IP_ADD_MEMBERSHIP), &mreq4, socklen_t(MemoryLayout<ip_mreq>.size)))
        #endif

        let socket4: CFSocket
        #if os(OSX)
            socket4 = CFSocketCreateWithNative(nil, fd4, CFSocketCallBackType.dataCallBack.rawValue, dataCallBack4, &context)
        #else
            socket4 = CFSocketCreateWithNative(nil, fd4, CFOptionFlags(kCFSocketDataCallBack), dataCallBack4, &context)
        #endif

        self.socket4 = (socket4, CFSocketCreateRunLoopSource(nil, socket4, 0))

//        #if os(OSX)
//            let fd6 = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
//        #else
//            let fd6 = socket(AF_INET6, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
//        #endif
//        guard fd6 >= 0 else {
//            throw POSIXError()
//        }
//
//        // allow reuse
//        try posix(setsockopt(fd6, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<UInt32>.size)))
//
//        // bind to IPv6 interface
//        let (_, ipv6) = sockaddr_storage.fromSockAddr { (sin: inout sockaddr_in6) in
//            sin.sin6_family = sa_family_t(AF_INET6)
//            sin.sin6_addr = in6addr_any
//            sin.sin6_port = (5353 as in_port_t).bigEndian
//        }
//        try ipv6.withSockAddr {
//            try posix(bind(fd6, $0, $1))
//        }
//
//        // subscribe to IPv6 mDNS multicast
//        let group6 = IPv6("FF02::FB")!
//        var mreq6 = ipv6_mreq(ipv6mr_multiaddr: group6.address, ipv6mr_interface: 1)
//        #if os(OSX)
//            try posix(setsockopt(fd6, IPPROTO_IPV6, IPV6_JOIN_GROUP, &mreq6, socklen_t(MemoryLayout<ipv6_mreq>.size)))
//        #else
//            try posix(setsockopt(fd6, Int32(IPPROTO_IPV6), IPV6_JOIN_GROUP, &mreq6, socklen_t(MemoryLayout<ipv6_mreq>.size)))
//        #endif
//
//        #if os(OSX)
//            socket6 = CFSocketCreateWithNative(nil, fd6, CFSocketCallBackType.dataCallBack.rawValue, dataCallBack6, &context)
//        #else
//            socket6 = CFSocketCreateWithNative(nil, fd6, CFOptionFlags(kCFSocketDataCallBack), dataCallBack6, &context)
//        #endif
//
//        runLoopSource6 = CFSocketCreateRunLoopSource(nil, socket6, 0)
    }

    func multicast(data: Data) {
        var ipv4Group = sockaddr_in()
        ipv4Group.sin_family = sa_family_t(AF_INET)
        ipv4Group.sin_addr = IPv4("224.0.0.251")!.address
        ipv4Group.sin_port = (5353 as in_port_t).bigEndian
        unicast(to: &ipv4Group, data: data, socket: socket4!.0)

        //todo send to ipv6 group as well
    }

    func unicast<AddrType>(to address: inout AddrType, data: Data, socket: CFSocket) where AddrType: SockAddr {
        address.withSockAddr { (sa, saLen) in
            sa.withMemoryRebound(to: UInt8.self, capacity: Int(saLen)) {
                let address = CFDataCreateWithBytesNoCopy(nil, $0, Int(saLen), kCFAllocatorNull)!
                #if os(OSX)
                    precondition(CFSocketSendData(socket, address, data.bridge(), 2) == .success)
                #else
                    precondition(CFSocketSendData(socket, address, data.bridge(), 2) == kCFSocketSuccess)
                #endif
            }
        }
    }
}

func dataCallBack4(socket: CFSocket?, callBackType: CFSocketCallBackType, address: CFData?, data: UnsafeRawPointer?, info: UnsafeMutableRawPointer?) {
    let address = UnsafeRawPointer(CFDataGetBytePtr(address!)!).bindMemory(to: sockaddr_in.self, capacity: 1).pointee
    let data = (Unmanaged<CFData>.fromOpaque(data!).takeUnretainedValue().bridge())
    let _self = Unmanaged<UDPChannel>.fromOpaque(info!).takeUnretainedValue()
    _self.received?(address, data, socket!)
}

func dataCallBack6(socket: CFSocket?, callBackType: CFSocketCallBackType, address: CFData?, data: UnsafeRawPointer?, info: UnsafeMutableRawPointer?) {
    let address = UnsafeRawPointer(CFDataGetBytePtr(address!)!).bindMemory(to: sockaddr_in6.self, capacity: 1).pointee
    let data = (Unmanaged<CFData>.fromOpaque(data!).takeUnretainedValue().bridge())
    let _self = Unmanaged<UDPChannel>.fromOpaque(info!).takeUnretainedValue()
    _self.received?(address, data, socket!)
}

