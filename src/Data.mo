import RbTree "mo:base/RBTree";
import Order "mo:base/Order";
import Int "mo:base/Int";
import Deque "mo:base/Deque";
import Principal "mo:base/Principal";

module {
  type Value = {
    var lock : Bool;
    var credit : Nat;
    var deposit : Nat;
  };

  class State<K>(compare : (K, K) -> Order.Order) {
    public let tree = RbTree.RBTree<K, Value>(compare);
    public var queue = Deque.empty<Value>();
    public var lookupCount = 0;
    public var size : Nat = 0;
    public var locks : Nat = 0;
    public var credit_sum : Nat = 0;
    public var deposits_count : Nat = 0;
    public var deposit_sum : Nat = 0;
  };

  public class Entry<K>(inside_ : Bool, key_ : K, value : Value, state : State<K>) {
    var inside = inside_;

    func cleanOrAdd() {
      let empty = value.lock == false and value.credit == 0 and value.deposit == 0;
      if (inside and empty) {
        state.lookupCount += 1;
        state.size -= 1;
        inside := false;
        state.tree.delete(key_);
      } else if (not inside and not empty) {
        state.lookupCount += 1;
        state.size += 1;
        inside := true;
        state.tree.put(key_, value);
      };
    };

    public func key() : K = key_;

    public func locked() : Bool = value.lock;

    public func lock() : Bool {
      if (value.lock) return false;
      value.lock := true;
      state.locks += 1;
      cleanOrAdd();
      true;
    };

    public func unlock() : Bool {
      if (not value.lock) return false;
      value.lock := false;
      state.locks -= 1;
      cleanOrAdd();
      true;
    };

    public func credit() : Nat = value.credit;

    public func changeCredit(add : Int) : Bool {
      let sum = value.credit + add;
      if (sum < 0) return false;
      value.credit := Int.abs(sum);
      state.credit_sum := Int.abs(state.credit_sum + add);
      cleanOrAdd();
      true;
    };

    public func deposit() : Nat = value.credit;

    public func setDeposit(deposit : Nat) {
      if (value.deposit != 0) state.deposits_count -= 1;
      state.deposit_sum -= value.deposit;

      value.deposit := deposit;

      if (value.deposit != 0) state.deposits_count += 1;
      state.deposit_sum += value.deposit;

      cleanOrAdd();
    };
  };

  class Map<K>(compare : (K, K) -> Order.Order) {
    let state : State<K> = State<K>(compare);

    public func getOpt(key : K) : ?Entry<K> {
      state.lookupCount += 1;
      let value = state.tree.get(key);
      switch (value) {
        case (?v) ?Entry<K>(true, key, v, state);
        case (null) null;
      };
    };

    public func get(key : K) : Entry<K> {
      state.lookupCount += 1;
      let value = state.tree.get(key);
      switch (value) {
        case (?v) Entry<K>(true, key, v, state);
        case (null) Entry<K>(false, key, { var lock = false; var credit = 0; var deposit = 0 }, state);
      };
    };
  };

  class Queue<K>() {
    var queue = Deque.empty<Entry<K>>();

    public func popFirst(f : (entry : Entry<K>) -> Bool) : ?Entry<K> {
      label l loop {
        let ?(entry, d) = Deque.popFront(queue) else break l;
        queue := d;
        if (f(entry)) return ?entry;
      };
      return null;
    };

    public func push(entry : Entry<K>) {
      queue := Deque.pushBack(queue, entry);
    };
  };

  public class Data() {
    public let map : Map<Principal> = Map<Principal>(Principal.compare);
    public let queue : Queue<Principal> = Queue<Principal>();
    public var pool = 0;
    public var ledgerFee = 0;
    public var surcharge = 0;
  };
};
