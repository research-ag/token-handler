import RbTree "mo:base/RBTree";
import Order "mo:base/Order";
import Int "mo:base/Int";
import Nat "mo:base/Nat";

module {
  type Value = {
    var lock : Bool;
    var credit : Nat;
    var deposit : Nat;
  };

  public type StableData<K> = {
    tree : RbTree.Tree<K, Value>;
    depositsTree : RbTree.Tree<(deposit : Nat, key : K), Value>;
    pool : Nat;
    lookupCount : Nat;
    size : Nat;
    locks : Nat;
    credit_sum : Nat;
    deposits_count : Nat;
    deposit_sum : Nat;
    unusable_deposit : {
      correct : Bool;
      sum : Nat;
    };
  };

  class State<K>(compare : (K, K) -> Order.Order) {
    public let tree = RbTree.RBTree<K, Value>(compare);

    public let depositsTree = RbTree.RBTree<(deposit : Nat, key : K), Value>(
      func((d1, k1), (d2, k2)) {
        let c = Nat.compare(d1, d2);
        if (c != #equal) return c;
        compare(k1, k2);
      }
    );

    public var pool : Nat = 0;

    public var lookupCount = 0;

    public var size : Nat = 0;

    public var locks : Nat = 0;

    public var credit_sum : Nat = 0;

    public var deposits_count : Nat = 0;

    public var deposit_sum : Nat = 0;

    public let unusable_deposit = {
      var correct = true;
      var sum = 0;
    };

    public func share() : StableData<K> = {
      tree = tree.share();
      depositsTree = depositsTree.share();
      pool;
      lookupCount;
      size;
      locks;
      credit_sum;
      deposits_count;
      deposit_sum;
      unusable_deposit = {
        correct = unusable_deposit.correct;
        sum = unusable_deposit.sum;
      };
    };

    public func unshare(data : StableData<K>) {
      tree.unshare(data.tree);
      depositsTree.unshare(data.depositsTree);
      pool := data.pool;
      lookupCount := data.lookupCount;
      size := data.size;
      locks := data.locks;
      credit_sum := data.credit_sum;
      deposits_count := data.deposits_count;
      deposit_sum := data.deposit_sum;
      unusable_deposit.correct := data.unusable_deposit.correct;
      unusable_deposit.sum := data.unusable_deposit.sum;
    };
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

    public func deposit() : Nat = value.deposit;

    public func setDeposit(deposit : Nat) {
      if (value.deposit != 0) {
        state.depositsTree.delete((value.deposit, key_));
        state.deposits_count -= 1;
      };
      state.deposit_sum -= value.deposit;

      value.deposit := deposit;

      state.deposit_sum += value.deposit;
      if (value.deposit != 0) {
        state.deposits_count += 1;
        state.depositsTree.put((value.deposit, key_), value);
      };

      state.unusable_deposit.correct := false;

      cleanOrAdd();
    };
  };

  public class Data<K>(compare : (K, K) -> Order.Order) {
    let state : State<K> = State<K>(compare);

    /// Retrieves the total credited funds in the pool.
    public func poolBalance() : Nat = state.pool;

    public func changePool(amount : Int) : Bool {
      let sum = state.pool + amount;
      if (sum < 0) return false;
      state.pool := Int.abs(sum);
      true;
    };

    public func getOpt(key : K) : ?Entry<K> {
      state.lookupCount += 1;
      let value = state.tree.get(key);
      switch (value) {
        case (?v) ?Entry<K>(true, key, v, state);
        case null null;
      };
    };

    public func get(key : K) : Entry<K> {
      state.lookupCount += 1;
      let value = state.tree.get(key);
      switch (value) {
        case (?v) Entry<K>(true, key, v, state);
        case null Entry<K>(false, key, { var lock = false; var credit = 0; var deposit = 0 }, state);
      };
    };

    public func lookupCount() : Nat = state.lookupCount;

    public func size() : Nat = state.size;

    public func locks() : Nat = state.locks;

    public func creditSum() : Nat = state.credit_sum;

    public func depositsCount() : Nat = state.deposits_count;

    public func depositSum() : Nat = state.deposit_sum;

    func maxDeposit() : Nat {
      let ?((deposit, _), _) = state.depositsTree.entriesRev().next() else return 0;
      deposit;
    };

    func updateUnusableDeposit(threshold : Nat) : Bool {
      let correct = maxDeposit() <= threshold;
      if (correct) state.unusable_deposit.sum := state.deposit_sum;
      state.unusable_deposit.correct := correct;
      return correct;
    };

    public func getMaxEligibleDeposit(threshold : Nat) : ?Entry<K> {
      if (updateUnusableDeposit(threshold)) return null;
      for (((deposit, key), value) in state.depositsTree.entriesRev()) {
        if (deposit <= threshold) return null;
        if (not value.lock) return ?Entry(true, key, value, state);
      };
      return null;
    };

    public func thresholdChanged(newThreshold : Nat) = ignore updateUnusableDeposit(newThreshold);

    public func usableDeposit() : (deposit : Int, correct : Bool) = (
      state.deposit_sum : Int - state.unusable_deposit.sum : Int,
      state.unusable_deposit.correct,
    );

    public func share() : StableData<K> = state.share();

    public func unshare(data : StableData<K>) = state.unshare(data);
  };
};
