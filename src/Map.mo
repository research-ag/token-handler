import RbTree "mo:base/RBTree";
import Order "mo:base/Order";
import Option "mo:base/Option";
import Int "mo:base/Int";
import Debug "mo:base/Debug";
import Deque "mo:base/Deque";

module {
  public class Data<K>(compare : (K, K) -> Order.Order, fee : () -> Nat) {
    type Entry<K> = {
      key : K;
      var lock : Bool;
      var credit : Int;
      var deposit : Nat;
    };

    func normalize<K>(e : Entry<K>, minimum : Nat) {
      if (e.deposit <= minimum) {
        e.deposit := 0;
      };
    };

    func balance_<K>(e : Entry<K>) : Int = e.credit + (if (e.deposit <= fee()) 0 else e.deposit - fee());

    class Map<K>(compare : (K, K) -> Order.Order) {
      let tree = RbTree.RBTree<K, Entry<K>>(compare);

      var size_ : Nat = 0;
      var locks_ : Nat = 0;
      var balance_sum : Int = 0;
      var non_zero_deposits : Nat = 0;
      var deposit_sum : Nat = 0;

      var lookupCount = 0;

      func change<K>(e : Entry<K>, mul : Int) {
        size_ := Int.abs(size_ + mul);
        if (e.lock) locks_ := Int.abs(locks_ + mul);
        balance_sum += mul * balance_(e);
        if (e.deposit != 0) non_zero_deposits := Int.abs(non_zero_deposits + mul);
        deposit_sum := Int.abs(deposit_sum + mul * e.deposit);
      };

      public func get(key : K) : ?Entry<K> {
        lookupCount += 1;
        tree.get(key);
      };

      public func put(key : K, value : Entry<K>) {
        lookupCount += 1;
        let prev = tree.replace(key, value);
        Option.iterate<Entry<K>>(prev, func(e) = change(e, -1));
        change(value, 1);
      };

      public func remove(key : K) : ?Entry<K> {
        lookupCount += 1;
        let prev = tree.remove(key);
        Option.iterate<Entry<K>>(prev, func(e) = change(e, -1));
        prev;
      };

      public func map<T>(e : Entry<K>, f : (e : Entry<K>) -> T) : T {
        change(e, -1);
        let result = f(e);
        change(e, 1);
        result;
      };
    };

    let map = Map<K>(compare);

    public func lockDeposit(key : K) : ?((?Nat) -> Nat) {
      Debug.trap("Unimplemented");
    };

    // public func popLock() : 

    class Queue<K>(compare : (K, K) -> Order.Order) {
      var queue = Deque.empty<Entry<K>>();

      public func popFirst(f : (e : Entry<K>) -> Bool) : ?Entry<K> {
        label l loop {
          let ?(e, d) = Deque.popFront(queue) else break l;
          queue := d;
          if (f(e)) return ?e;
        };
        return null;
      };

      public func push(e : Entry<K>) {
        queue := Deque.pushBack(queue, e);
      };
    };
  };
};
