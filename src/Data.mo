import Int "mo:core/Int";
import { type Iter } "mo:core/Types";
import List "mo:core/pure/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Order "mo:core/Order";

module {
  type Value = {
    var lock : Bool;
    var credit : Nat;
    var deposit : Nat;
  };

  public type StableData<K> = {
    tree : Map.Map<K, Value>;
    depositsTree : Map.Map<(deposit : Nat, key : K), Value>;
    handlerPool : Int;
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
    public var tree = Map.empty<K, Value>();

    public let treeCompare = compare;

    public var depositsTree = Map.empty<(deposit : Nat, key : K), Value>();

    public let depositsTreeCompare : ((Nat, K), (Nat, K)) -> Order.Order = func((d1, k1), (d2, k2)) {
      let c = Nat.compare(d1, d2);
      if (c != #equal) return c;
      compare(k1, k2);
    };

    public var handlerPool : Int = 0;

    public var lookupCount : Nat = 0;

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
      tree = tree;
      depositsTree = depositsTree;
      handlerPool;
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
      tree := data.tree;
      depositsTree := data.depositsTree;
      handlerPool := data.handlerPool;
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
        state.tree.remove(state.treeCompare, key_);
      } else if (not inside and not empty) {
        state.lookupCount += 1;
        state.size += 1;
        inside := true;
        state.tree.add(state.treeCompare, key_, value);
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
        state.depositsTree.remove(state.depositsTreeCompare, (value.deposit, key_));
        state.deposits_count -= 1;
      };
      state.deposit_sum -= value.deposit;

      value.deposit := deposit;

      state.deposit_sum += value.deposit;
      if (value.deposit != 0) {
        state.deposits_count += 1;
        state.depositsTree.add(state.depositsTreeCompare, (value.deposit, key_), value);
      };

      state.unusable_deposit.correct := false;

      cleanOrAdd();
    };
  };

  public class Data<K>(compare : (K, K) -> Order.Order) {
    let state : State<K> = State<K>(compare);

    /// Retrieves the total credited funds in the pool.
    public func handlerPoolBalance() : Int = state.handlerPool;

    public func changeHandlerPool(amount : Int) {
      state.handlerPool += amount;
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
      let ?((deposit, _), _) = state.depositsTree.reverseEntries().next() else return 0;
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
      for (((deposit, key), value) in state.depositsTree.reverseEntries()) {
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

  type Tree<K, V> = {
    #node : ({ #R; #B }, Tree<K, V>, (K, ?V), Tree<K, V>);
    #leaf;
  };
  public type StableDataV1<K> = {
    tree : Tree<K, Value>;
    depositsTree : Tree<(deposit : Nat, key : K), Value>;
    handlerPool : Int;
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

  public func migrateStableDataV1<K>(data : StableDataV1<K>, cmp : (implicit : (K, K) -> Order.Order)) : StableData<K> {
    func migrateTree<K, V>(tree : Tree<K, V>, cmp : (implicit : (K, K) -> Order.Order)) : Map.Map<K, V> {
      // copied from mo:base/RBTree source code
      type IterRep<X, Y> = List.List<{ #tr : Tree<X, Y>; #xy : (X, ?Y) }>;
      func iter<X, Y>(tree : Tree<X, Y>) : Iter<(X, Y)> {
        object {
          var trees : IterRep<X, Y> = ?(#tr(tree), null);
          public func next() : ?(X, Y) {
            switch (trees) {
              case (null) { null };
              case (?(#tr(#leaf), ts)) {
                trees := ts;
                next();
              };
              case (?(#xy(xy), ts)) {
                trees := ts;
                switch (xy.1) {
                  case null { next() };
                  case (?y) { ?(xy.0, y) };
                };
              };
              case (?(#tr(#node(_, l, xy, r)), ts)) {
                trees := ?(#tr(l), ?(#xy(xy), ?(#tr(r), ts)));
                next();
              };
            };
          };
        };
      };
      let map = Map.empty<K, V>();
      for ((k, v) in iter(tree)) {
        map.add(cmp, k, v);
      };
      map;
    };

    {
      data with
      tree = migrateTree(data.tree, cmp);
      depositsTree = migrateTree(
        data.depositsTree,
        func((d1, k1), (d2, k2)) {
          let c = Nat.compare(d1, d2);
          if (c != #equal) return c;
          cmp(k1, k2);
        },
      );
    };
  };

};
