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

    /// Notifies of a deposit and schedules consolidation process.
    /// Returns the newly detected deposit if successful.
    /// Returns null if:
    /// - the lock cannot be obtained
    /// - the ledger could not be called
    /// - notifications are paused entirely
    /// This function never throws.
    public func notify(p : Principal) : async* ?(Nat, Nat) {
      func do_notify() : async* ?(Nat, Nat) {
        let #ok latestDeposit = await* icrc84.loadDeposit(p) else return null;

        if (latestDeposit <= feeManager.fee()) {
          return ?(0, 0);
        };
        let prevDeposit = entry.deposit();
        if (latestDeposit < prevDeposit) trap("latestDeposit < prevDeposit on notify");
        if (latestDeposit == prevDeposit) return ?(0, 0);

        let depositInc = latestDeposit - prevDeposit : Nat;
        let creditInc = if (prevDeposit == 0) latestDeposit - feeManager.fee() : Nat else depositInc;

        if (prevDeposit == 0) {
          queue.pushBack(entry);
        };

        entry.setDeposit(latestDeposit);
        assert entry.changeCredit(creditInc);
        totalCredited += creditInc;

        log(p, #newDeposit(depositInc));

        if (triggerOnNotifications) {
          // schedule a canister self-call to initiate the consolidation
          // we need try-catch so that we don't trap if scheduling fails synchronously
          try ignore async await* trigger(1) catch (_) {};
        };
        return ?(depositInc, creditInc);
      };

      if (paused) return null;
      let entry = map.get(p);
      if (not entry.lock()) return null;

      let ret = await* do_notify();

      assert entry.unlock();
      return ret;
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
          queue.pushBack(entry);
          entry.setDeposit(deposit);
        };
      };
      assert entry.unlock();

      res;
    };

    /// Triggers the processing deposits.
    /// n - desired number of potential consolidations.
    public func trigger(n : Nat) : async* () {
      for (i in Iter.range(1, n)) {
        let stack = Data.Queue<Principal>();

        func search() : ?Data.Entry<Principal> {
          loop {
            let ?entry = queue.popFront() else return null;

            if (entry.deposit() > feeManager.fee()) {
              if (entry.locked()) stack.pushBack(entry) else return ?entry;
            } else {
              entry.setDeposit(0);
            };
          };
        };

        func addBack() {
          loop {
            let ?entry = stack.popBack() else return;
            queue.pushFront(entry);
          };
        };

        let ?entry = search() else return;
        addBack();

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
      totalConsolidated
    );

    /// Deserializes the token handler data.
    public func unshare(values : StableData) {
      totalConsolidated := values;
    };
  };
};
