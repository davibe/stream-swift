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

fileprivate class Weak<T: AnyObject> {
    weak var value : T?
    init(_ value: T) {
        self.value = value
    }
    func get() -> T? {
        return value
    }
}


public class Stream<T> : Disposable {
    
    public typealias StreamHandler = (T) -> ()
    private var subscriptions = [Weak<Subscription<T>>]()
    var disposables = [Disposable]()
    var valuePresent = false
    var value: T?
    
    // sub apis

    @discardableResult
    func subscribe(
        _ target: AnyObject,
        replay: Bool = false,
        strong: Bool = true,
        line: Int = #line,
        file: String = #file,
        function: String = #function,
        _ handler: @escaping StreamHandler
    ) -> Subscription<T> {
        let subscription = Subscription<T>(target: target, stream: self, strong: strong, handler: handler)
        
        #if DEBUG
        let filename = URL(fileURLWithPath: file).lastPathComponent
        subscription.debugString = "\(filename):\(line) in \(function)"
        SubscriptionTracker.sharedInstance.plus(key: subscription.debugString!)
        #endif
        
        subscriptions.append(Weak(subscription))
        if strong {
            subscriptionRegistry.append(subscription)
        }
        
        if replay && valuePresent { handler(self.value!) }
        return subscription
    }
    
    func unsubscribe(_ target: AnyObject) {
        subscriptions = subscriptions.filter {
            guard let sub = $0.get() else { return true }
            let include = sub.target !== target
            if (!include && sub.strong) {
                subscriptionRegistry = subscriptionRegistry.filter { $0 !== sub }
            }
            return include
            
        }
    }
    
    @discardableResult
    func subscribe(
        replay: Bool = false,
        strong: Bool = true,
        line: Int = #line,
        file: String = #file,
        function: String = #function,
        _ handler: @escaping StreamHandler
    ) -> Subscription<T> {
        let subscription = Subscription<T>(target: self, stream: self, strong:strong, handler: handler)
        
        #if DEBUG
        let filename = URL(fileURLWithPath: file).lastPathComponent
        subscription.debugString = "\(filename):\(line) in \(function)"
        SubscriptionTracker.sharedInstance.plus(key: subscription.debugString!)
        #endif
        
        subscriptions.append(Weak(subscription))
        if strong {
            subscriptionRegistry.append(subscription)
        }

        if replay && valuePresent { handler(self.value!) }
        return subscription
    }
    
    func unsubscribe(_ sub: Subscription<T>) {
        subscriptions = subscriptions.filter { $0.get() !== sub }
        if sub.strong {
            subscriptionRegistry = subscriptionRegistry.filter { $0 !== sub }
        }
    }
    
    // last value
    
    internal func last(cb: (T) -> Void) {
        if (valuePresent) {
            return cb(value!)
        }
    }
    
    // chainables
    
    @discardableResult
    func trigger(_ value: T) -> Stream<T> {
        self.value = value
        valuePresent = true
        subscriptions.forEach { (subscription) in
            subscription.get()?.handler(value)
        }
        return self
    }
    
    @discardableResult
    func map<U>(fn: @escaping (T) -> U) -> Stream<U> {
        let stream = Stream<U>()
        if valuePresent { stream.trigger(fn(value!)) }
        stream.disposables += [subscribe(strong: false) { [weak stream] v in
            stream?.trigger(fn(v))
        }]
        return stream
        
    }
    
    func distinct<U: Equatable>(_ f: @escaping (T) -> U) -> Stream<T> {
        let stream = Stream<T>()
        if (valuePresent) { stream.trigger(value!) }
        var started = false
        let sub = subscribe(replay: true, strong: false) { [weak stream, weak self] v in
            if (started) { return }
            started = true
            var prev = v
            stream?.trigger(prev)
            let sub = self?.subscribe(replay: false, strong: false) { [weak stream] next in
                if f(next) != f(prev) {
                    stream?.trigger(next)
                    prev = next
                }
            }
            if let stream = stream, let sub = sub {
                stream.disposables += [sub]
            }
        }
        stream.disposables += [sub]
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


fileprivate var subscriptionRegistry = [AnyObject]()

public class Subscription<T>: Disposable, CustomStringConvertible {
    public typealias StreamHandler = (T) -> ()
    weak var target: AnyObject? = nil
    let stream: Stream<T>
    let handler: StreamHandler
    var debugString: String? = nil
    var strong: Bool = false
    
    public var description: String {
        get {
            guard let debugString = debugString else {
                return "Subscription for \(String(describing: T.self))"
            }
            return "Subscription for \(String(describing: T.self)) at \(debugString)"
        }
    }
    
    init(target: AnyObject, stream: Stream<T>, strong: Bool, handler: @escaping (T) -> ()) {
        self.target = target
        self.stream = stream
        self.strong = strong
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
    
    func reset() { allocations = [:] }
    
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
    let trigger: () -> Void = { [weak stream] in
        a.last { va in
            b.last { vb in
                stream?.trigger((va, vb))
            }
        }
    }
    stream.disposables += [
        a.subscribe(strong: true) { (_) in trigger() },
        b.subscribe(strong: true) { (_) in trigger() }
    ]
    // destroying when all parents die
    var count = 2
    let disposer = DisposableFunc() { [weak stream] in
        count -= 1
        if count == 0 {
            stream?.dispose()
        }
    }
    a.disposables += [disposer]
    b.disposables += [disposer]
    return stream
}

func combine<A, B, C>(_ a: Stream<A>, _ b: Stream<B>, _ c: Stream<C>) -> Stream<(A, B, C)> {
    let stream = Stream<(A, B, C)>()
    let trigger: () -> Void = { [weak stream] in
        a.last { va in
            b.last { vb in
                c.last { vc in
                    stream?.trigger((va, vb, vc))
                }
            }
        }
    }
    stream.disposables += [
        a.subscribe { (_) in trigger() },
        b.subscribe { (_) in trigger() },
        c.subscribe { (_) in trigger() }
    ]
    // destroying when all parents die
    var count = 3
    let disposer = DisposableFunc() { [weak stream] in
        count -= 1
        if count == 0 {
            stream?.dispose()
        }
    }
    a.disposables += [disposer]
    b.disposables += [disposer]
    c.disposables += [disposer]
    return stream
}

func combine<A, B, C, D>(_ a: Stream<A>, _ b: Stream<B>, _ c: Stream<C>, _ d: Stream<D>) -> Stream<(A, B, C, D)> {
    let stream = Stream<(A, B, C, D)>()
    let trigger: () -> Void = { [weak stream] in
        a.last { va in
            b.last { vb in
                c.last { vc in
                    d.last { vd in
                        stream?.trigger((va, vb, vc, vd))
                    }
                }
            }
        }
    }
    stream.disposables += [
        a.subscribe { (_) in trigger() },
        b.subscribe { (_) in trigger() },
        c.subscribe { (_) in trigger() },
        d.subscribe { (_) in trigger() }
    ]
    // destroying when all parents die
    var count = 4
    let disposer = DisposableFunc() { [weak stream] in
        count -= 1
        if count == 0 {
            stream?.dispose()
        }
    }
    a.disposables += [disposer]
    b.disposables += [disposer]
    c.disposables += [disposer]
    d.disposables += [disposer]
    return stream
}

func combine<A, B, C, D, E>(_ a: Stream<A>, _ b: Stream<B>, _ c: Stream<C>, _ d: Stream<D>, _ e: Stream<E>) -> Stream<(A, B, C, D, E)> {
    let stream = Stream<(A, B, C, D, E)>()
    let trigger: () -> Void = { [weak stream] in
        a.last { va in
            b.last { vb in
                c.last { vc in
                    d.last { vd in
                        e.last { ve in
                            stream?.trigger((va, vb, vc, vd, ve))
                        }
                    }
                }
            }
        }
    }
    stream.disposables += [
        a.subscribe { (_) in trigger() },
        b.subscribe { (_) in trigger() },
        c.subscribe { (_) in trigger() },
        d.subscribe { (_) in trigger() },
        e.subscribe { (_) in trigger() }
    ]
    // destroying when all parents die
    var count = 5
    let disposer = DisposableFunc() { [weak stream] in
        count -= 1
        if count == 0 {
            stream?.dispose()
        }
    }
    a.disposables += [disposer]
    b.disposables += [disposer]
    c.disposables += [disposer]
    d.disposables += [disposer]
    e.disposables += [disposer]
    return stream
}

func combine<A, B, C, D, E, F>(_ a: Stream<A>, _ b: Stream<B>, _ c: Stream<C>, _ d: Stream<D>, _ e: Stream<E>, _ f: Stream<F>) -> Stream<(A, B, C, D, E, F)> {
    let stream = Stream<(A, B, C, D, E, F)>()
    let trigger: () -> Void = { [weak stream] in
        a.last { va in
            b.last { vb in
                c.last { vc in
                    d.last { vd in
                        e.last { ve in
                            f.last { vf in
                                stream?.trigger((va, vb, vc, vd, ve, vf))
                            }
                        }
                    }
                }
            }
        }
    }
    stream.disposables += [
        a.subscribe { (_) in trigger() },
        b.subscribe { (_) in trigger() },
        c.subscribe { (_) in trigger() },
        d.subscribe { (_) in trigger() },
        e.subscribe { (_) in trigger() },
        f.subscribe { (_) in trigger() }
    ]
    // destroying when all parents die
    var count = 6
    let disposer = DisposableFunc() { [weak stream] in
        count -= 1
        if count == 0 {
            stream?.dispose()
        }
    }
    a.disposables += [disposer]
    b.disposables += [disposer]
    c.disposables += [disposer]
    d.disposables += [disposer]
    e.disposables += [disposer]
    f.disposables += [disposer]
    return stream
}
