import Principal "mo:base/Principal";
import R "mo:base/Result";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";

import ICRC1 "icrc1-api"; // only needed for error types
import ICRC84Helper "icrc84-helper";
import Data "Data";
import FeeManager "FeeManager";

module {
  public type StableData = (
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
    let { map } = data;

    /// If `true` new notifications are paused.
    var paused : Bool = false;

    /// Total amount consolidated. Accumulated value.
    var totalConsolidated : Nat = 0;

    /// Total amount of credited to users.
    var totalCredited : Nat = 0;

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
        credited = totalCredited;
      };
      totalConsolidated = totalConsolidated;
      funds = {
        deposited = map.depositSum() + underwayFunds;
        underway = underwayFunds;
        queued = map.depositSum();
      };
      nDeposits = map.depositsCount();
      nLocks = map.locks();
    };

    /// Pause or unpause notifications.
    public func pause(b : Bool) = paused := b;

    /// Retrieves the deposit of a principal.
    public func getDeposit(p : Principal) : ?Nat = switch (map.getOpt(p)) {
      case null null;
      case (?entry) ?entry.deposit();
    };

    func do_notify(p : Principal, entry : Data.Entry<Principal>) : async* ?(Nat, Nat) {
      // This call never throws:
      let #ok latestDeposit = await* icrc84.loadDeposit(p) else return null;

      if (latestDeposit <= feeManager.fee()) {
        return ?(0, 0);
      };

      let prevDeposit = entry.deposit();
      if (latestDeposit < prevDeposit) trap("latestDeposit < prevDeposit on notify");
      if (latestDeposit == prevDeposit) return ?(0, 0);
      entry.setDeposit(latestDeposit);

      let depositInc = latestDeposit - prevDeposit : Nat;
      let creditInc = depositInc - (if (prevDeposit == 0) feeManager.fee() else 0) : Nat;

      assert entry.changeCredit(creditInc);
      totalCredited += creditInc;

      log(p, #newDeposit(depositInc));

      if (triggerOnNotifications) {
        // schedule a canister self-call to initiate the consolidation
        // we need try-catch so that we don't throw if scheduling fails synchronously
        // Try this out in practice: https://play.motoko.org/?tag=2588339575
        try ignore async await* trigger(1) catch (_) {};
      };
      return ?(depositInc, creditInc);
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

      let ret = try {
        await* do_notify(p, entry);
      } finally assert entry.unlock();

      return ret;
    };

    func post_transfer(entry : Data.Entry<Principal>, (ledgerFee, surcharge) : (Nat, Nat), res : ICRC84Helper.TransferResult) {
      let deposit = entry.deposit();
      underwayFunds -= deposit;

      // log event
      let event = switch (res) {
        case (#ok _) #consolidated({
          deducted = deposit;
          credited = deposit - ledgerFee - surcharge : Nat;
        });
        case (#err err) #consolidationError(err);
      };
      log(entry.key(), event);

      // process result
      switch (res) {
        case (#ok _) {
          totalConsolidated += deposit - ledgerFee;
          data.pool += surcharge;
          entry.setDeposit(0);
        };
        case (#err _) {}
      };

      assert entry.unlock();
    };

    /// Attempts to consolidate the funds for a particular principal.
    /// This function never throws.
    func consolidate(entry : Data.Entry<Principal>) : async* TransferResponse {
      assert entry.lock();
      underwayFunds += entry.deposit();

      let fees = feeManager.share();

      // transfer funds to the main account
      var trapped = true;
      let res = try {
        // TODO: put a unique memo in this call
        let res = await* icrc84.consolidate(entry.key(), entry.deposit()); // this call never throws
        trapped := false;
        res
      } finally {
        if (trapped) {
          // we leave underwayFunds intentionally unchanged
          // we leave the entry intentionally locked
          // TODO:
          // log the context: (entry.key(), fees, memo)
          // then we can later figure out res and replay post_transfer(entry, fees, res)
        }
      };

      post_transfer(entry, fees, res);

      res;
    };

    /// Triggers the processing deposits.
    /// n - desired number of potential consolidations.
    public func trigger(n : Nat) : async* () {
      for (i in Iter.range(1, n)) {
        let ?entry = map.getMaxEligibleDeposit(feeManager.fee()) else return;
        let res = await* consolidate(entry); // this call never throws
        if (res == #err(#CallIcrc1LedgerError)) return;
      };
    };

    /// Serializes the token handler data.
    public func share() : StableData = (
      totalConsolidated
    );

    /// Deserializes the token handler data.
    public func unshare(values : StableData) {
      totalConsolidated := values;
    };
  };
};
