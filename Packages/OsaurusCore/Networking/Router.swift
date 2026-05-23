//
//  Router.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//  Intel fork — minimal routing (cloud-only). M3 milestone.
//

import Foundation
import IkigaJSON
import NIOCore
import NIOHTTP1

public struct Router {
    var context: ChannelHandlerContext?
    weak var handler: HTTPHandler?

    private static func makeJSONDecoder() -> IkigaJSONDecoder { IkigaJSONDecoder() }
    private func makeJSONEncoder() -> IkigaJSONEncoder { IkigaJSONEncoder() }

    init(context: ChannelHandlerContext? = nil, handler: HTTPHandler? = nil) {
        self.context = context
        self.handler = handler
    }

    public func route(method: String, path: String, body: Data = Data()) -> (
        status: HTTPResponseStatus, headers: [(String, String)], body: String
    ) {
        let p = normalize(path)
        if method == "HEAD" { return headOkEndpoint() }

        switch (method, p) {
        case ("GET", "/health"):
            return healthEndpoint()
        case ("GET", "/"):
            return rootEndpoint()
        default:
            return stubOkEndpoint(path: p)
        }
    }

    public func route(method: String, path: String, bodyBuffer: ByteBuffer) -> (
        status: HTTPResponseStatus, headers: [(String, String)], body: String
    ) {
        let p = normalize(path)
        if method == "HEAD" { return headOkEndpoint() }

        switch (method, p) {
        case ("GET", "/health"):
            return healthEndpoint()
        case ("GET", "/"):
            return rootEndpoint()
        default:
            return stubOkEndpoint(path: p)
        }
    }

    // MARK: - Endpoints

    private func healthEndpoint() -> (HTTPResponseStatus, [(String, String)], String) {
        var obj = JSONObject()
        obj["status"] = "healthy"
        obj["timestamp"] = Date().ISO8601Format()
        return (.ok, [("Content-Type", "application/json; charset=utf-8")], obj.string)
    }

    private func rootEndpoint() -> (HTTPResponseStatus, [(String, String)], String) {
        return (.ok, [("Content-Type", "text/plain; charset=utf-8")], "Osaurus (Intel) is running! 🦕")
    }

    private func stubOkEndpoint(path: String) -> (HTTPResponseStatus, [(String, String)], String) {
        var obj = JSONObject()
        obj["status"] = "ok"
        obj["path"] = path
        return (.ok, [("Content-Type", "application/json; charset=utf-8")], obj.string)
    }

    private func headOkEndpoint() -> (HTTPResponseStatus, [(String, String)], String) {
        return (.noContent, [("Content-Type", "text/plain; charset=utf-8")], "")
    }

    // MARK: - Helpers

    /// Static path normalizer usable without a Router instance.
    public static func normalizeStatic(_ path: String) -> String {
        func stripPrefix(_ prefix: String, from s: String) -> String? {
            if s == prefix { return "/" }
            if s.hasPrefix(prefix + "/") {
                let idx = s.index(s.startIndex, offsetBy: prefix.count)
                let rest = String(s[idx...])
                return rest.isEmpty ? "/" : rest
            }
            return nil
        }
        if let r = stripPrefix("/v1/api", from: path) { return r }
        if let r = stripPrefix("/api", from: path) { return r }
        if let r = stripPrefix("/v1", from: path) { return r }
        return path
    }

    private func normalize(_ path: String) -> String {
        Self.normalizeStatic(path)
    }
}
