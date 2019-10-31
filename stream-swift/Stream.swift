//
//  Stream.swift
//
//  Created by Davide Bertola on 07/02/2018.
//

import Foundation

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


public class Stream<T> : Disposable, AllocationTrackable {
    
    public typealias StreamHandler = (T) -> ()
    private var subscriptions = [Weak<Subscription<T>>]()
    var disposables = [Disposable]()
    var valuePresent = false
    var value: T?
    
    var debugKey: String = ""
    
    init() {
        var trackable = self as AllocationTrackable
        AllocationTracker.sharedInstance.plus(&trackable, type: "Stream")
    }
    
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
        
        var trackable = subscription as AllocationTrackable
        if strong {
            AllocationTracker.sharedInstance.plus(&trackable, type: "Subscription", line: line, file: file, function: function)
        } else {
            AllocationTracker.sharedInstance.plus(&trackable, type: "Subscription")
        }
        
        subscriptions.append(Weak(subscription))
        if strong { subscriptionRegistry.append(subscription) }
        
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
    
    // sub apis based on ownership (deprecated)
    
    @discardableResult
    func subscribe(
        replay: Bool = false,
        strong: Bool = true,
        line: Int = #line,
        file: String = #file,
        function: String = #function,
        _ handler: @escaping StreamHandler
    ) -> Subscription<T> {
        let subscription = Subscription<T>(target: self, stream: self, strong: strong, handler: handler)
        
        #if DEBUG
        var trackable = subscription as AllocationTrackable
        if strong {
            AllocationTracker.sharedInstance.plus(&trackable, type: "Subscription", line: line, file: file, function: function)
        } else {
            AllocationTracker.sharedInstance.plus(&trackable, type: "Subscription", line: line)
        }
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
        stream.disposables += [subscribe(replay: true, strong: false) { [weak stream] v in
            stream?.trigger(fn(v))
        }]
        return stream
    }
    
    func distinct<U: Equatable>(_ f: @escaping (T) -> U) -> Stream<T> {
        let stream = Stream<T>()
        
        var waitingFirst = !self.valuePresent
        stream.disposables = [self.subscribe(replay: false, strong: false) { [weak stream] next in
            guard let stream = stream else { return }
            if waitingFirst || f(next) != f(stream.value!) {
                stream.trigger(next)
                waitingFirst = false
            }
        }]
        
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
    
    func filter(_ f: @escaping (T) -> Bool) -> Stream<T> {
        let stream = Stream<T>()
        stream.disposables += [subscribe(replay: true, strong: false) { [weak stream] v in
            guard let stream = stream else { return }
            if f(v) { stream.trigger(v) }
        }]
        return stream
    }
    
    func take(_ amount: Int) -> Stream<T> {
        let stream = Stream<T>()
        var count = 0
        stream.disposables += [subscribe(replay: true, strong: false) { [weak stream] v in
            guard let stream = stream else { return }
            if count <= amount {
                stream.trigger(v)
                count += 1
            } else {
                stream.dispose()
            }
        }]
        return stream
    }
    
    func dispose() {
        subscriptions = []
        disposables.forEach({ $0.dispose() })
        disposables = []
        value = nil
        valuePresent = false
        if debugKey != "" { AllocationTracker.sharedInstance.minus(self) }
    }
    
    deinit {
        dispose()
    }
}


fileprivate var subscriptionRegistry = [AnyObject]()

public class Subscription<T>: Disposable, CustomStringConvertible, AllocationTrackable {
    public typealias StreamHandler = (T) -> ()
    weak var target: AnyObject? = nil
    let stream: Stream<T>
    let handler: StreamHandler
    var strong: Bool = false
    var debugKey: String = ""
    
    public var description: String {
        get {
            if debugKey != "" {
                return "Subscription for \(String(describing: T.self))"
            }
            return "Subscription for \(String(describing: T.self)) at \(debugKey)"
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
        if debugKey != "" { AllocationTracker.sharedInstance.minus(self) }
    }
    
}

protocol AllocationTrackable {
    var debugKey: String { get set }
}

class AllocationTracker {
    static let sharedInstance = AllocationTracker()
    private var allocations: [String:Int]
    
    private init() {
        allocations = [:]
    }
    
    func plus(
        _ trackable: inout AllocationTrackable,
        type: String,
        key: String? = nil,
        line: Int? = nil,
        file: String? = nil,
        function: String? = nil
    ) {
        #if !DEBUG
        return
        #endif
        
        let generated = generate()
        var key = "\(type)\n  \(generated)"
        
        if let line = line, let file = file, let function = function {
            let filename = URL(fileURLWithPath: file).lastPathComponent
            let location = "\(filename):\(line) in \(function)"
            key = "\(type)\n  \(location)\n"
        }

        trackable.debugKey = key
        var value = allocations[key] ?? 0
        value += 1
        allocations[key] = value
    }
    
    func minus(_ trackable: AllocationTrackable) {
        #if !DEBUG
        return
        #endif
        
        var value = allocations[trackable.debugKey] ?? 1
        value -= 1
        allocations[trackable.debugKey] = value
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
                print("LEAK \(allocation.key)")
                value = false
            }
        }
        return value
    }
    
    func generate() -> String {
        // TODO: find a way to have a nicer stack trace
        return Thread.callStackSymbols[2...10].joined(separator: "\n  ")
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
