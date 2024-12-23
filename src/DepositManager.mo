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
  public type StableData = {
    totalConsolidated : Nat;
    paused : Bool;
    totalCredited : Nat;
    underwayFunds : Nat;
  };

  public type State = {
    paused : Bool;
    totalConsolidated : Nat;
    totalCredited : Nat;
    funds : {
      deposited : Nat;
      underway : Nat;
      queued : Nat;
    };
  };

  public type ConsolidationError = ICRC1.TransferError or {
    #CallIcrc1LedgerError;
  };

  public type LogEvent = {
    #issued : Int;
    #newDeposit : Nat;
    #consolidated : {
      deducted : Nat;
      credited : Nat;
    };
    #consolidationError : ConsolidationError;
  };

  public type TransferResponse = R.Result<Nat, ConsolidationError>;

  /// Manages deposits from users, handles consolidation operations.
  /// icrc84 must be configured with the correct previous fee after an upgrade
  public class DepositManager(
    icrc84 : ICRC84Helper.Ledger,
    triggerOnNotifications : Bool,
    data : Data.Data<Principal>,
    feeManager : FeeManager.FeeManager,
    log : (Principal, LogEvent) -> (),
    trap : (text : Text) -> (),
  ) {
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
      totalCredited;
      totalConsolidated;
      funds = {
        deposited = data.depositSum();
        underway = underwayFunds;
        queued = data.depositSum() - underwayFunds;
      };
    };

    /// Pause or unpause notifications.
    public func pause(b : Bool) = paused := b;

    func do_notify(p : Principal, entry : Data.Entry<Principal>) : async* ?(Nat, Nat) {
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
      
      feeManager.addFee();

      let surcharge = feeManager.surcharge();
      data.changeHandlerPool(surcharge);
      log(Principal.fromBlob(""), #issued(surcharge));

      log(p, #issued(creditInc));
      log(p, #newDeposit(depositInc));

      if (triggerOnNotifications) {
        // schedule a canister self-call to initiate the consolidation
        // we need try-catch so that we don't trap if scheduling fails synchronously
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
      let entry = data.get(p);
      if (not entry.lock()) return null;

      let ret = await* do_notify(p, entry);

      assert entry.unlock();
      return ret;
    };

    /// Attempts to consolidate the funds for a particular principal.
    func consolidate(entry : Data.Entry<Principal>) : async* TransferResponse {
      // read deposit amount from registry and erase it
      // we will add it again if the consolidation fails
      assert entry.lock();
      let deposit = entry.deposit();
      underwayFunds += deposit;

      let consolidated : Nat = deposit - feeManager.ledgerFee();

      // transfer funds to the main account
      let res = await* icrc84.consolidate(entry.key(), deposit);

      // log event
      let event = switch (res) {
        case (#ok _) #consolidated({
          deducted = deposit;
          credited = consolidated;
        });
        case (#err err) #consolidationError(err);
      };
      log(entry.key(), event);

      // process result
      switch (res) {
        case (#ok _) {
          totalConsolidated += consolidated;
          entry.setDeposit(0);
        };
        case (#err _) {};
      };

      underwayFunds -= deposit;

      assert entry.unlock();

      res;
    };

    /// Triggers the processing deposits.
    /// n - desired number of potential consolidations.
    public func trigger(n : Nat) : async* () {
      for (i in Iter.range(1, n)) {
        let ?entry = data.getMaxEligibleDeposit(feeManager.ledgerFee()) else return;

        let result = await* consolidate(entry);

        switch (result) {
          case (#err(#CallIcrc1LedgerError)) return;
          case _ {};
        };
      };
    };

    /// Serializes the token handler data.
    public func share() : StableData = {
      totalConsolidated;
      paused;
      totalCredited;
      underwayFunds;
    };

    /// Deserializes the token handler data.
    public func unshare(values : StableData) {
      totalConsolidated := values.totalConsolidated;
      paused := values.paused;
      totalCredited := values.totalCredited;
      underwayFunds := values.underwayFunds;
    };
  };
};
