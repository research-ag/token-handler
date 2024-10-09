import Principal "mo:base/Principal";
import Int "mo:base/Int";
import R "mo:base/Result";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";

import ICRC1 "icrc1-api"; // only needed for error types
import ICRC84Helper "icrc84-helper";
import DepositRegistry "DepositRegistry";
import Data "Data";
import FeeManager "FeeManager";

module {
  public type StableData = (
    DepositRegistry.StableData, // depositRegistry
    Nat, // totalConsolidated
  );

  public type State = {
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
    nLocks : Nat;
  };

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
    data : Data.Data,
    feeManager : FeeManager.FeeManager,
    log : (Principal, LogEvent) -> (),
    trap : (text : Text) -> (),
  ) {
    let { map; queue } = data;

    /// If `true` new notifications are paused.
    var paused : Bool = false;

    /// Manages deposit balances for each user.
    // let depositRegistry = DepositRegistry.DepositRegistry(icrc84.fee(), trap);
    // let depositMap = depositRegistry.map;

    /// Total amount consolidated. Accumulated value.
    var totalConsolidated : Nat = 0;

    /// Total funds underway for consolidation.
    var underwayFunds : Nat = 0;

    public func state() : State = {
      paused = paused;
      fee = {
        ledger = feeManager.ledgerFee();
        deposit = feeManager.fee();
        surcharge = feeManager.surcharge();
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
    // public func setSurcharge(s : Nat) {
    //   log(Principal.fromBlob(""), #surchargeUpdated({ old = surcharge(); new = s }));
    //   depositRegistry.updateFee(icrc84.fee() + s, credit.changeUser);
    // };

    /// Retrieves the deposit of a principal.
    public func getDeposit(p : Principal) : ?Nat = switch (map.getOpt(p)) {
      case null null;
      case (?entry) ?entry.deposit();
    };

    /// Object to track all credit flows initiated from within DepositManager.
    /// The flow should never become negative.
    // let credit = object {
    //   public var flow : Int = 0;
    //   public func change(who : { #user : Principal; #pool }, amount : Int) {
    //     changeCredit(who, amount);
    //     flow += amount;
    //     if (flow < 0) trap("credit flow went negative");
    //   };
    //   public func changeUser(p : Principal, amount : Int) = change(#user p, amount);
    //   public func changePool(amount : Int) = change(#pool, amount);
    // };

    // get informed by updated ledger fee
    // public func registerFeeChange(oldFee : Nat, newFee : Nat) {
    //   assert oldFee != newFee;
    //   // set new deposit fee such that the surcharge remains the same
    //   depositRegistry.updateFee(depositRegistry.fee + newFee - oldFee, credit.changeUser);
    //   log(Principal.fromBlob(""), #feeUpdated({ old = oldFee; new = newFee }));
    // };

    func process_deposit(p : Principal, deposit : Nat, release : ?Nat -> Int) : (Nat, Nat) {
      if (deposit <= feeManager.fee()) {
        ignore release(null);
        return (0, 0);
      };
      let delta = release(?deposit);
      if (delta < 0) trap("latestDeposit < prevDeposit on notify");
      if (delta == 0) return (0, 0);
      let inc = Int.abs(delta);

      let creditInc : Nat = switch (deposit == inc) {
        case true { deposit - feeManager.fee() }; // former value in DepositRegistry was 0
        case false { inc }; // former value in DepositRegistry was > 0
      };

      credit.changeUser(p, creditInc);
      (inc, creditInc);
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
      let entry = map.get(p);
      if (not entry.lock()) return null;

      let latestDeposit = switch (await* icrc84.loadDeposit(p)) {
        case (#ok x) x;
        case (#err _) {
          assert entry.unlock();
          return null;
        };
      };

      // This function calls release() to release the lock
      // let (inc, creditInc) = process_deposit(p, latestDeposit, release);
      if (latestDeposit <= feeManager.fee()) {
        assert entry.unlock();
        return ?(0, 0);
      };
      let prevDeposit = entry.deposit();
      if (latestDeposit < prevDeposit) trap("latestDeposit < prevDeposit on notify");
      if (latestDeposit == prevDeposit) return ?(0, 0);

      let depositInc = latestDeposit - prevDeposit : Nat;
      let creditInc = if (prevDeposit == 0) latestDeposit - feeManager.fee() : Nat else depositInc;

      if (prevDeposit == 0) {
        queue.push(entry);
      };

      entry.setDeposit(latestDeposit);
      assert entry.changeCredit(creditInc);
      assert entry.unlock();

      log(p, #newDeposit(depositInc));

      if (triggerOnNotifications) {
        // schedule a canister self-call to initiate the consolidation
        // we need try-catch so that we don't trap if scheduling fails synchronously
        try ignore async await* trigger(1) catch (_) {};
      };

      return ?(depositInc, creditInc);
    };

    /// Attempts to consolidate the funds for a particular principal.
    func consolidate(entry : Data.Entry<Principal>) : async* TransferResponse {
      // read deposit amount from registry and erase it
      // we will add it again if the consolidation fails
      let deposit = entry.deposit();
      entry.setDeposit(0);

      let consolidated : Nat = deposit - feeManager.ledgerFee();
      let credited : Nat = deposit - feeManager.fee();

      // transfer funds to the main account
      let res = await* icrc84.consolidate(entry.key(), deposit);

      // log event
      let event = switch (res) {
        case (#ok _) #consolidated({
          deducted = deposit;
          credited;
        });
        case (#err err) #consolidationError(err);
      };
      log(entry.key(), event);

      // process result
      switch (res) {
        case (#ok _) {
          totalConsolidated += consolidated;
          data.pool += feeManager.surcharge();
        };
        case (#err _) {
          entry.setDeposit(deposit);
          // credit.changeUser(p, -credited);
          // // the fees may have changed in the meantime, hence we process the exising deposit as a new one
          // ignore process_deposit(p, deposit, release);
        };
      };
      assert entry.unlock();

      res;
    };

    /// Triggers the processing deposits.
    /// n - desired number of potential consolidations.
    public func trigger(n : Nat) : async* () {
      for (i in Iter.range(1, n)) {
        func condition(e : Data.Entry<Principal>) : Bool {
          let ok = e.deposit() > feeManager.fee();
          if (not ok) e.setDeposit(0);
          ok;
        };
        let ?entry = queue.popFirst(condition) else return;
        underwayFunds += entry.deposit();
        let result = await* consolidate(entry);
        underwayFunds -= entry.deposit();
        switch (result) {
          case (#err(#CallIcrc1LedgerError)) return;
          case _ {};
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
