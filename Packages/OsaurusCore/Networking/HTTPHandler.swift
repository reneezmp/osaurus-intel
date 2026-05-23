//
//  HTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//  Intel fork — minimal handler returning 200 for all routes. M3 milestone.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

private final class SendableBool: @unchecked Sendable {
    private var _value: Bool
    private let _lock = NSLock()
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { _lock.withLock { _value } }
        set { _lock.withLock { _value = newValue } }
    }
}

final class HTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let configuration: ServerConfiguration
    private let apiKeyValidatorProvider: @Sendable () -> APIKeyValidator
    private var apiKeyValidator: APIKeyValidator { apiKeyValidatorProvider() }
    private let trustLoopback: Bool
    private let _isChannelActive = SendableBool(false)

    final class RequestState {
        var requestHead: HTTPRequestHead?
        var requestBodyBuffer: ByteBuffer?
    }
    let stateRef: NIOLoopBound<RequestState>

    init(
        configuration: ServerConfiguration,
        apiKeyValidator: APIKeyValidator = .empty,
        apiKeyValidatorProvider: (@Sendable () -> APIKeyValidator)? = nil,
        eventLoop: EventLoop,
        trustLoopback: Bool = true
    ) {
        self.configuration = configuration
        self.apiKeyValidatorProvider = apiKeyValidatorProvider ?? { apiKeyValidator }
        self.trustLoopback = trustLoopback
        self.stateRef = NIOLoopBound(RequestState(), eventLoop: eventLoop)
    }

    func channelActive(context: ChannelHandlerContext) {
        _isChannelActive.value = true
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        _isChannelActive.value = false
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            stateRef.value.requestHead = head
            stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var buffer):
            if stateRef.value.requestBodyBuffer != nil {
                stateRef.value.requestBodyBuffer!.writeBuffer(&buffer)
            }

        case .end:
            guard let head = stateRef.value.requestHead else {
                sendEmptyResponse(context: context, status: .badRequest)
                return
            }

            if let bodyBytes = try? authCheck(head: head, context: context) {
                return
            }

            let method = head.method.rawValue
            let path = head.uri

            var router = Router(context: context, handler: self)
            let bodyBuffer = stateRef.value.requestBodyBuffer ?? context.channel.allocator.buffer(capacity: 0)
            let (status, headers, body) = router.route(method: method, path: path, bodyBuffer: bodyBuffer)

            sendResponse(context: context, status: status, headers: headers, body: body)
        }
    }

    private func authCheck(head: HTTPRequestHead, context: ChannelHandlerContext) -> Error? {
        let validator = apiKeyValidator

        if validator.hasKeys && !trustLoopback {
            guard let apiKey = head.headers["Authorization"].first ?? head.headers["x-api-key"].first else {
                sendJSONError(context: context, status: .unauthorized, message: "API key required")
                return NSError(domain: "auth", code: 401)
            }

            let raw = apiKey.hasPrefix("Bearer ") ? String(apiKey.dropFirst(7)) : apiKey
            let result = validator.validate(rawKey: raw)
            if case .valid = result { } else {
                sendJSONError(context: context, status: .unauthorized, message: "Invalid API key")
                return NSError(domain: "auth", code: 401)
            }
        }

        return nil
    }

    private func sendResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String
    ) {
        var responseHeaders = HTTPHeaders()
        responseHeaders.add(name: "content-type", value: "application/json; charset=utf-8")
        for (name, value) in headers {
            responseHeaders.add(name: name, value: value)
        }
        responseHeaders.add(name: "content-length", value: String(body.utf8.count))
        responseHeaders.add(name: "connection", value: "keep-alive")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: responseHeaders)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendEmptyResponse(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        let head = HTTPResponseHead(version: .http1_1, status: status)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendJSONError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        let body = "{\"error\":{\"message\":\"\(message)\"}}"
        let headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")]
        sendResponse(context: context, status: status, headers: headers, body: body)
    }
}
