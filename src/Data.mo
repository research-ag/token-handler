import Int "mo:core/Int";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Order "mo:core/Order";

module {
  type Value = {
    var lock : Bool;
    var credit : Nat;
    var deposit : Nat;
  };

  func depositsCompare<K>(compare : (K, K) -> Order.Order) : ((Nat, K), (Nat, K)) -> Order.Order = func((d1, k1), (d2, k2)) {
    let c = Nat.compare(d1, d2);
    if (c != #equal) return c;
    compare(k1, k2);
  };

  public module Entry {
    public type Entry<K> = {
      var inside : Bool;
      key_ : K;
      value : Value;
      state : Data.Data<K>;
    };

    func cleanOrAdd<K>(self : Entry<K>, compare : (K, K) -> Order.Order) {
      let empty = self.value.lock == false and self.value.credit == 0 and self.value.deposit == 0;
      if (self.inside and empty) {
        self.state.lookupCount_ += 1;
        self.state.size_ -= 1;
        self.inside := false;
        self.state.tree.remove(compare, self.key_);
      } else if (not self.inside and not empty) {
        self.state.lookupCount_ += 1;
        self.state.size_ += 1;
        self.inside := true;
        self.state.tree.add(compare, self.key_, self.value);
      };
    };

    public func key<K>(self : Entry<K>) : K = self.key_;

    public func locked<K>(self : Entry<K>) : Bool = self.value.lock;

    public func lock<K>(self : Entry<K>, compare : (implicit : (K, K) -> Order.Order)) : Bool {
      if (self.value.lock) return false;
      self.value.lock := true;
      self.state.locks_ += 1;
      cleanOrAdd(self, compare);
      true;
    };

    public func unlock<K>(self : Entry<K>, compare : (implicit : (K, K) -> Order.Order)) : Bool {
      if (not self.value.lock) return false;
      self.value.lock := false;
      self.state.locks_ -= 1;
      cleanOrAdd(self, compare);
      true;
    };

    public func credit<K>(self : Entry<K>) : Nat = self.value.credit;

    public func changeCredit<K>(self : Entry<K>, compare : (implicit : (K, K) -> Order.Order), add : Int) : Bool {
      let sum = self.value.credit + add;
      if (sum < 0) return false;
      self.value.credit := Int.abs(sum);
      self.state.credit_sum := Int.abs(self.state.credit_sum + add);
      cleanOrAdd(self, compare);
      true;
    };

    public func deposit<K>(self : Entry<K>) : Nat = self.value.deposit;

    public func setDeposit<K>(self : Entry<K>, compare : (implicit : (K, K) -> Order.Order), deposit : Nat) {
      if (self.value.deposit != 0) {
        self.state.depositsTree.remove(depositsCompare(compare), (self.value.deposit, self.key_));
        self.state.deposits_count -= 1;
      };
      self.state.deposit_sum -= self.value.deposit;

      self.value.deposit := deposit;

      self.state.deposit_sum += self.value.deposit;
      if (self.value.deposit != 0) {
        self.state.deposits_count += 1;
        self.state.depositsTree.add(depositsCompare(compare), (self.value.deposit, self.key_), self.value);
      };

      self.state.unusable_deposit.correct := false;

      cleanOrAdd(self, compare);
    };
  };

  public module Data {
    public type Data<K> = {
      var tree : Map.Map<K, Value>;
      var depositsTree : Map.Map<(deposit : Nat, key : K), Value>;
      var handlerPool : Int;
      var lookupCount_ : Nat;
      var size_ : Nat;
      var locks_ : Nat;
      var credit_sum : Nat;
      var deposits_count : Nat;
      var deposit_sum : Nat;
      unusable_deposit : {
        var correct : Bool;
        var sum : Nat;
      };
    };

    public func empty<K>() : Data<K> = {
      var tree = Map.empty<K, Value>();
      var depositsTree = Map.empty<(deposit : Nat, key : K), Value>();
      var handlerPool = 0;
      var lookupCount_ = 0;
      var size_ = 0;
      var locks_ = 0;
      var credit_sum = 0;
      var deposits_count = 0;
      var deposit_sum = 0;
      unusable_deposit = {
        var correct = true;
        var sum = 0;
      };
    };

    /// Retrieves the total credited funds in the pool.
    public func handlerPoolBalance<K>(self : Data<K>) : Int = self.handlerPool;

    public func changeHandlerPool<K>(self : Data<K>, amount : Int) {
      self.handlerPool += amount;
    };

    /// Returns the entry for `key` when it is present in the registry, `null` otherwise.
    public func get<K>(self : Data<K>, compare : (implicit : (K, K) -> Order.Order), key : K) : ?Entry.Entry<K> {
      self.lookupCount_ += 1;
      let value = self.tree.get(compare, key);
      switch (value) {
        case (?v) ?{ var inside = true; key_ = key; value = v; state = self };
        case null null;
      };
    };

    /// Returns the entry for `key`, creating a fresh detached entry when it is not present.
    public func entry<K>(self : Data<K>, compare : (implicit : (K, K) -> Order.Order), key : K) : Entry.Entry<K> {
      self.lookupCount_ += 1;
      let value = self.tree.get(compare, key);
      switch (value) {
        case (?v) ({ var inside = true; key_ = key; value = v; state = self });
        case null ({
          var inside = false;
          key_ = key;
          value = { var lock = false; var credit = 0; var deposit = 0 };
          state = self;
        });
      };
    };

    public func lookupCount<K>(self : Data<K>) : Nat = self.lookupCount_;

    public func size<K>(self : Data<K>) : Nat = self.size_;

    public func locks<K>(self : Data<K>) : Nat = self.locks_;

    public func creditSum<K>(self : Data<K>) : Nat = self.credit_sum;

    public func depositsCount<K>(self : Data<K>) : Nat = self.deposits_count;

    public func depositSum<K>(self : Data<K>) : Nat = self.deposit_sum;

    func maxDeposit<K>(self : Data<K>) : Nat {
      let ?((deposit, _), _) = self.depositsTree.reverseEntries().next() else return 0;
      deposit;
    };

    func updateUnusableDeposit<K>(self : Data<K>, threshold : Nat) : Bool {
      let correct = maxDeposit(self) <= threshold;
      if (correct) self.unusable_deposit.sum := self.deposit_sum;
      self.unusable_deposit.correct := correct;
      return correct;
    };

    public func getMaxEligibleDeposit<K>(self : Data<K>, threshold : Nat) : ?Entry.Entry<K> {
      if (updateUnusableDeposit(self, threshold)) return null;
      for (((deposit, key), value) in self.depositsTree.reverseEntries()) {
        if (deposit <= threshold) return null;
        if (not value.lock) return ?{
          var inside = true;
          key_ = key;
          value;
          state = self;
        };
      };
      return null;
    };

    public func thresholdChanged<K>(self : Data<K>, newThreshold : Nat) = ignore updateUnusableDeposit(self, newThreshold);

    public func usableDeposit<K>(self : Data<K>) : (deposit : Int, correct : Bool) = (
      self.deposit_sum : Int - self.unusable_deposit.sum : Int,
      self.unusable_deposit.correct,
    );
  };
};
