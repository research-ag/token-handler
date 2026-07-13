import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import { type Result } "mo:core/Types";

import { Data; Entry } "Data";
import FeeManager "FeeManager";
import ICRC1 "icrc1-api"; // only needed for error types
import ICRC84Helper "icrc84-helper";

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
    #newDeposit : {
      depositInc : Nat;
      creditInc : Nat;
      ledgerFee : Nat;
      surcharge : Nat;
    };
    #depositInc : Nat;
    #consolidated : {
      deducted : Nat;
      credited : Nat;
      fee : Nat;
    };
  };

  public type TransferResponse = Result<Nat, ConsolidationError>;

  public type DepositManager = {
    var paused : Bool;
    var totalConsolidated : Nat;
    var totalCredited : Nat;
    var underwayFunds : Nat;
  };

  public func new() : DepositManager {
    {
      var paused = false;
      var totalConsolidated = 0;
      var totalCredited = 0;
      var underwayFunds = 0;
    };
  };

  public func state(self : DepositManager, data : Data.Data<Principal>) : State = {
    paused = self.paused;
    totalCredited = self.totalCredited;
    totalConsolidated = self.totalConsolidated;
    funds = {
      deposited = data.depositSum();
      underway = self.underwayFunds;
      queued = data.depositSum() - self.underwayFunds;
    };
  };

  /// Pause or unpause notifications.
  public func pause(self : DepositManager, b : Bool) {
    self.paused := b;
  };

  func do_notify(
    self : DepositManager,
    icrc84 : ICRC84Helper.Ledger,
    data : Data.Data<Principal>,
    feeManager : FeeManager.FeeManager,
    log : (Principal, LogEvent) -> (),
    trap : (text : Text) -> (),
    triggerOnNotifications : Bool,
    p : Principal,
    entry : Entry.Entry<Principal>,
  ) : async* ?(Nat, Nat) {
    let #ok latestDeposit = await* ICRC84Helper.loadDeposit(icrc84, p) else return null;

    if (latestDeposit <= feeManager.fee(icrc84)) {
      return ?(0, 0);
    };

    let prevDeposit = entry.deposit();
    if (latestDeposit < prevDeposit) trap("latestDeposit < prevDeposit on notify");
    if (latestDeposit == prevDeposit) return ?(0, 0);
    entry.setDeposit(latestDeposit);

    let depositInc = latestDeposit - prevDeposit : Nat;
    let creditInc = depositInc - (if (prevDeposit == 0) feeManager.fee(icrc84) else 0) : Nat;

    assert entry.changeCredit(creditInc);
    self.totalCredited += creditInc;

    if (prevDeposit == 0) {
      let surcharge = feeManager.surcharge;
      let ledgerFee = feeManager.ledgerFee(icrc84);
      feeManager.addFee(icrc84);
      data.changeHandlerPool(surcharge);
      log(
        p,
        #newDeposit {
          depositInc;
          creditInc;
          ledgerFee;
          surcharge;
        },
      );
    } else {
      log(p, #depositInc(depositInc));
    };

    if (triggerOnNotifications) {
      // schedule a canister self-call to initiate the consolidation
      // we need try-catch so that we don't trap if scheduling fails synchronously
      try ignore async await* trigger(self, icrc84, data, feeManager, log, 1) catch (_) {};
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
  public func notify(
    self : DepositManager,
    icrc84 : ICRC84Helper.Ledger,
    data : Data.Data<Principal>,
    feeManager : FeeManager.FeeManager,
    log : (Principal, LogEvent) -> (),
    trap : (text : Text) -> (),
    triggerOnNotifications : Bool,
    p : Principal,
  ) : async* ?(Nat, Nat) {
    if (self.paused) return null;
    let entry = data.entry(p);
    if (not entry.lock()) return null;

    let ret = await* do_notify(self, icrc84, data, feeManager, log, trap, triggerOnNotifications, p, entry);

    assert entry.unlock();

    return ret;
  };

  /// Attempts to consolidate the funds for a particular principal.
  func consolidate(
    self : DepositManager,
    icrc84 : ICRC84Helper.Ledger,
    feeManager : FeeManager.FeeManager,
    log : (Principal, LogEvent) -> (),
    entry : Entry.Entry<Principal>,
  ) : async* TransferResponse {
    // read deposit amount from registry and erase it
    // we will add it again if the consolidation fails
    assert entry.lock();
    let deposit = entry.deposit();
    self.underwayFunds += deposit;

    let fee = feeManager.ledgerFee(icrc84);
    let consolidated : Nat = deposit - fee;

    // transfer funds to the main account
    let res = await* ICRC84Helper.consolidate(icrc84, entry.key(), deposit);

    // process result
    switch (res) {
      case (#ok _) {
        self.totalConsolidated += consolidated;
        entry.setDeposit(0);
        feeManager.subtractFee(fee);
        log(entry.key(), #consolidated({ deducted = deposit; credited = consolidated; fee }));
      };
      case (#err _) {};
    };

    self.underwayFunds -= deposit;

    assert entry.unlock();

    res;
  };

  /// Triggers the processing deposits.
  /// n - desired number of potential consolidations.
  public func trigger(
    self : DepositManager,
    icrc84 : ICRC84Helper.Ledger,
    data : Data.Data<Principal>,
    feeManager : FeeManager.FeeManager,
    log : (Principal, LogEvent) -> (),
    n : Nat,
  ) : async* () {
    for (_ in Nat.range(0, n)) {
      let ?entry = data.getMaxEligibleDeposit(feeManager.ledgerFee(icrc84)) else return;

      let result = await* consolidate(self, icrc84, feeManager, log, entry);

      switch (result) {
        case (#err(#CallIcrc1LedgerError)) return;
        case _ {};
      };
    };
  };
};
