import Principal "mo:base/Principal";
import Int "mo:base/Int";
import R "mo:base/Result";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";

import ICRC1 "icrc1-api"; // only needed for error types
import ICRC84Helper "icrc84-helper";
import DepositRegistry "DepositRegistry";

module {
  public type StableData = (
    DepositRegistry.StableData, // depositRegistry
    Nat, // totalConsolidated
  );

  public type LogEvent = {
    #feeUpdated : { old : Nat; new : Nat };
    #surchargeUpdated : { old : Nat; new : Nat };
    #newDeposit : Nat;
    #consolidated : { deducted : Nat; credited : Nat };
    #consolidationError : Errors.TransferMin;
  };

  module Errors {
    public type Transfer = ICRC1.TransferError or { #CallIcrc1LedgerError };
    public type TransferFrom = ICRC1.TransferFromError or {
      #CallIcrc1LedgerError;
    };
    public type TransferMin = Transfer or { #TooLowQuantity };
  };

  public type TransferResponse = R.Result<Nat, Errors.Transfer>;

  /// Manages deposits from users, handles consolidation operations.
  /// icrc84 must be configured with the correct previous fee after an upgrade
  public class DepositManager(
    icrc84 : ICRC84Helper.Ledger,
    triggerOnNotifications : Bool,
    changeCredit : ({ #pool; #user : Principal }, Int) -> (),
    log : (Principal, LogEvent) -> (),
    trap : (text : Text) -> (),
  ) {
    /// If `true` new notifications are paused.
    var paused : Bool = false;

    /// Manages deposit balances for each user.
    let depositRegistry = DepositRegistry.DepositRegistry(icrc84.fee(), trap);
    let depositMap = depositRegistry.map;

    /// Total amount consolidated. Accumulated value.
    var totalConsolidated : Nat = 0;

    /// Total funds underway for consolidation.
    var underwayFunds : Nat = 0;

    func surcharge() : Nat = depositRegistry.fee - icrc84.fee();

    public func state() : {
      paused : Bool;
      fee : { ledger : Nat; deposit : Nat; surcharge : Nat };
      flow : { credited : Nat };
      totalConsolidated : Nat;
      funds : {
        deposited : Nat;
        underway : Nat;
        queued : Nat;
      };
      nDeposits : Nat;
    } = {
      paused = paused;
      fee = {
        ledger = icrc84.fee();
        deposit = depositRegistry.fee;
        surcharge = surcharge();
      };
      flow = {
        credited = Int.abs(credit.flow);
      };
      totalConsolidated = totalConsolidated;
      funds = {
        deposited = depositMap.sum() + underwayFunds;
        underway = underwayFunds;
        queued = depositMap.sum();
      };
      nDeposits = depositMap.size();
      nLocks = depositMap.locks();
    };

    /// Pause or unpause notifications.
    public func pause(b : Bool) = paused := b;

    /// Sets new surcharge amount.
    public func setSurcharge(s : Nat) {
      log(Principal.fromBlob(""), #surchargeUpdated({ old = surcharge(); new = s }));
      depositRegistry.updateFee(icrc84.fee() + s, credit.changeUser);
    };

    /// Retrieves the deposit of a principal.
    public func getDeposit(p : Principal) : ?Nat = depositMap.getOpt(p);

    /// Object to track all credit flows initiated from within DepositManager.
    /// The flow should never become negative.
    let credit = object {
      public var flow : Int = 0;
      public func change(who : { #user : Principal; #pool }, amount : Int) {
        changeCredit(who, amount);
        flow += amount;
        if (flow < 0) trap("credit flow went negative");
      };
      public func changeUser(p : Principal, amount : Int) = change(#user p, amount);
      public func changePool(amount : Int) = change(#pool, amount);
    };

    func process_deposit(p : Principal, deposit : Nat, release : ?Nat -> Int) : (Nat, Nat) {
      if (deposit <= depositRegistry.fee) {
        ignore release(null);
        return (0, 0);
      };
      let delta = release(?deposit);
      if (delta < 0) trap("latestDeposit < prevDeposit on notify");
      if (delta == 0) return (0, 0);
      let inc = Int.abs(delta);

      let creditInc : Nat = switch (deposit == inc) {
        case true { deposit - depositRegistry.fee }; // former value in DepositRegistry was 0
        case false { inc }; // former value in DepositRegistry was > 0
      };

      credit.changeUser(p, creditInc);
      (inc, creditInc);
    };

    // get informed by updated ledger fee
    public func updatedFee(oldFee : Nat, newFee : Nat) {
      assert oldFee != newFee;
      // set new deposit fee such that the surcharge remains the same
      depositRegistry.updateFee(depositRegistry.fee + newFee - oldFee, credit.changeUser);
      log(Principal.fromBlob(""), #feeUpdated({ old = oldFee; new = newFee }));
    };

    /// Notifies of a deposit and schedules consolidation process.
    /// Returns the newly detected deposit if successful.
    /// Returns null if:
    /// - the lock cannot be obtained
    /// - the ledger could not be called
    /// - notifications are paused entirely
    /// This function never throws.
    public func notify(p : Principal) : async* ?(Nat, Nat) {
      if (paused) return null;
      let ?release = depositMap.obtainLock(p) else return null;

      let latestDeposit = switch (await* icrc84.loadDeposit(p)) {
        case (#ok x) x;
        case (#err _) {
          ignore release(null);
          return null;
        };
      };

      // This function calls release() to release the lock
      let (inc, creditInc) = process_deposit(p, latestDeposit, release);

      if (inc > 0) {
        log(p, #newDeposit(inc));

        if (triggerOnNotifications) {
          // schedule a canister self-call to initiate the consolidation
          // we need try-catch so that we don't trap if scheduling fails synchronously
          try { ignore async { await* trigger(1) } } catch (_) {};
        };
      };

      return ?(inc, creditInc);
    };

    /// Attempts to consolidate the funds for a particular principal.
    func consolidate(p : Principal, release : ?Nat -> Int) : async* TransferResponse {
      // read deposit amount from registry and erase it
      // we will add it again if the consolidation fails
      let deposit = depositMap.erase(p);

      let consolidated : Nat = deposit - icrc84.fee();
      let credited : Nat = deposit - depositRegistry.fee;

      // transfer funds to the main account
      let res = await* icrc84.consolidate(p, deposit);

      // log event
      let event = switch (res) {
        case (#ok _) #consolidated({
          deducted = deposit;
          credited;
        });
        case (#err err) #consolidationError(err);
      };
      log(p, event);

      // process result
      switch (res) {
        case (#ok _) {
          totalConsolidated += consolidated;
          credit.changePool(consolidated - credited);
          ignore release(null);
        };
        case (#err _) {
          credit.changeUser(p, -credited);
          // the fees may have changed in the meantime, hence we process the exising deposit as a new one
          ignore process_deposit(p, deposit, release);
        };
      };

      res;
    };

    /// Triggers the processing deposits.
    /// n - desired number of potential consolidations.
    public func trigger(n : Nat) : async* () {
      for (i in Iter.range(1, n)) {
        let ?(p, deposit, release) = depositMap.nextLock() else return;
        underwayFunds += deposit;
        let result = await* consolidate(p, release);
        underwayFunds -= deposit;
        switch (result) {
          case (#err(#CallIcrc1LedgerError)) return;
          case (_) {};
        };
      };
    };

    /// Serializes the token handler data.
    public func share() : StableData = (
      depositRegistry.share(),
      totalConsolidated,
    );

    /// Deserializes the token handler data.
    public func unshare(values : StableData) {
      depositRegistry.unshare(values.0);
      totalConsolidated := values.1;
    };
  };
};
