//
//  Stream.swift
//
//  Created by Davide Bertola on 07/02/2018.
//

import Foundation

// MARK: - Disposable protocol
protocol Disposable {
    func dispose()
}

struct DisposableFunc: Disposable {
    let cb: () -> Void
    init(cb: @escaping () -> Void) {
        self.cb = cb
    }
    func dispose() {
        self.cb()
    }
}


public class Stream<T> : Disposable {
    
    public typealias StreamHandler = (T) -> ()
    public var subscriptions = [Subscription<T>]()
    var disposables = [Disposable]()
    var valuePresent = false
    var value: T?
    
    // sub apis

    @discardableResult func subscribe(
        _ target: AnyObject,
        replay: Bool = false,
        line: Int = #line,
        file: String = #file,
        function: String = #function,
        _ handler: @escaping StreamHandler
        ) -> Subscription<T> {
        let subscription = Subscription<T>(target: target, stream: self, handler: handler)
        
        #if DEBUG
        let filename = URL(fileURLWithPath: file).lastPathComponent
        subscription.debugString = "\(filename):\(line) in \(function)"
        SubscriptionTracker.sharedInstance.plus(key: subscription.debugString!)
        #endif
        
        subscriptions.append(subscription)
        if replay && valuePresent { handler(self.value!) }
        return subscription
    }
    
    func unsubscribe(_ target: AnyObject) {
        subscriptions = subscriptions.filter { $0.target !== target }
    }
    
    @discardableResult func subscribe(
        line: Int = #line,
        replay: Bool = false,
        file: String = #file,
        function: String = #function,
        _ handler: @escaping StreamHandler
    ) -> Subscription<T> {
        let subscription = Subscription<T>(target: self, stream: self, handler: handler)
        
        #if DEBUG
        let filename = URL(fileURLWithPath: file).lastPathComponent
        subscription.debugString = "\(filename):\(line) in \(function)"
        SubscriptionTracker.sharedInstance.plus(key: subscription.debugString!)
        #endif
        
        subscriptions.append(subscription)
        if replay && valuePresent { handler(self.value!) }
        return subscription
    }
    
    func unsubscribe(_ subscription: Subscription<T>) {
        subscriptions = subscriptions.filter { $0 !== subscription }
    }
    
    // last value
    
    internal func last(cb: (T) -> Void) {
        if (valuePresent) {
            return cb(value!)
        }
    }
    
    // chainables
    
    @discardableResult func trigger(_ value: T) -> Stream<T> {
        self.value = value
        valuePresent = true
        subscriptions.forEach { (subscription) in
            subscription.handler(value)
        }
        return self
    }
    
    func map<U>(fn: @escaping (T) -> U) -> Stream<U> {
        let stream = Stream<U>()
        disposables += [stream]
        if valuePresent { stream.trigger(fn(value!)) }
        stream.disposables += [subscribe() { v in
            stream.trigger(fn(v))
        }]
        return stream
        
    }
    
    func distinct<U: Equatable>(_ f: @escaping (T) -> U) -> Stream<T> {
        let stream = Stream<T>()
        disposables += [stream]
        if (valuePresent) { stream.trigger(value!) }
        var started = false
        subscribe(replay: true) { v in
            if (started) { return }
            started = true
            var prev = v
            stream.trigger(prev)
            self.subscribe(replay: false) { next in
                if (f(next) != f(prev)) {
                    stream.trigger(next)
                    prev = next
                }
            }
        }
        return stream
    }
    
    func fold<U>(initialValue: U, accumulator: @escaping ((U, T) -> U)) -> Stream<U> {
        var current = initialValue
        return map {
            let newValue = accumulator(current, $0)
            current = newValue
            return newValue
        }
    }
    
    func dispose() {
        subscriptions = []
        disposables.forEach({ $0.dispose() })
        disposables = []
        value = nil
        valuePresent = false
    }
}


public class Subscription<T>: Disposable, CustomStringConvertible {
    public typealias StreamHandler = (T) -> ()
    weak var target: AnyObject? = nil
    let stream: Stream<T>
    let handler: StreamHandler
    var debugString: String? = nil
    
    public var description: String {
        get {
            guard let debugString = debugString else {
                return "Subscription for \(String(describing: T.self))"
            }
            return "Subscription for \(String(describing: T.self)) at \(debugString)"
        }
    }
    
    init(target: AnyObject, stream: Stream<T>, handler: @escaping (T) -> ()) {
        self.target = target
        self.stream = stream
        self.handler = handler
    }
    
    func dispose() {
        stream.unsubscribe(self)
    }
    
    deinit {
        guard let debugString = self.debugString else { return }
        SubscriptionTracker.sharedInstance.minus(key: debugString)
    }
}


class SubscriptionTracker {
    static let sharedInstance = SubscriptionTracker()
    private var allocations: [String:Int]
    
    private init() {
        allocations = [:]
    }
    
    func plus(key: String) {
        
        #if !DEBUG
        return
        #endif
        
        var value = allocations[key] ?? 0
        value += 1
        allocations[key] = value
    }
    
    func minus(key: String) {
        
        #if !DEBUG
        return
        #endif
        
        var value = allocations[key] ?? 1
        value -= 1
        allocations[key] = value
    }
    
    @discardableResult
    func validate() -> Bool {
        var value = true
        
        #if !DEBUG
        return value
        #endif
        
        for allocation in allocations {
            if (allocation.value > 0) {
                print("Subscription LEAK at \(allocation.key)")
                value = false
            }
        }
        return value
    }
}

func combine<A, B>(_ a: Stream<A>, _ b: Stream<B>) -> Stream<(A, B)> {
    let stream = Stream<(A, B)>()
    let trigger: () -> Void = {
        a.last { va in
            b.last { vb in
                stream.trigger((va, vb))
            }
        }
    }
    a.subscribe { (_) in trigger() }
    b.subscribe { (_) in trigger() }
    var count = 2
    let disposer = DisposableFunc() {
        count -= 1
        if count == 0 {
            stream.dispose()
        }
    }
    a.disposables = [disposer]
    b.disposables = [disposer]
    return stream
}
