import Principal "mo:base/Principal";
import Int "mo:base/Int";
import R "mo:base/Result";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";

import ICRC1 "icrc1-api";
import ICRC84Helper "icrc84-helper";
import CreditRegistry "CreditRegistry";
import DepositRegistry "DepositRegistry";

module {
  public type StableData = (
    DepositRegistry.StableDataMap, // depositRegistry
    Nat, // ledgerFeee_
    Nat, // surcharge_
    Nat, // totalConsolidated_
    Nat, // totalWithdrawn_
  );

  public type LogEvent = {
    #feeUpdated : { old : Nat; new : Nat };
    #surchargeUpdated : { old : Nat; new : Nat };
    #newDeposit : Nat;
    #consolidated : { deducted : Nat; credited : Nat };
    #consolidationError : Errors.Ledger.TransferMin;
    #withdraw : { to : ICRC1.Account; amount : Nat };
    #withdrawalError : Errors.Withdraw;
    #allowanceDrawn : { amount : Nat };
    #allowanceError : Errors.DepositFromAllowance;
  };

  public type FeeType = {
    #deposit;
    #allowance;
    #withdrawal;
  };

  module Errors {
    public module Ledger {
      public type Transfer = ICRC1.TransferError or { #CallIcrc1LedgerError };
      public type TransferFrom = ICRC1.TransferFromError or {
        #CallIcrc1LedgerError;
      };
      public type TransferMin = Transfer or { #TooLowQuantity };
    };
    public type Withdraw = Ledger.TransferMin or { #InsufficientCredit };
    public type DepositFromAllowance = Ledger.TransferFrom;
  };

  type WithdrawResult = (transactionIndex : Nat, withdrawnAmount : Nat);
  type DepositFromAllowanceResult = (credited : Nat, txid : Nat);

  type Result<X, Y> = R.Result<X, Y>;
  public type WithdrawResponse = Result<WithdrawResult, Errors.Withdraw>;
  public type TransferResponse = Result<Nat, Errors.Ledger.Transfer>;
  public type DepositFromAllowanceResponse = Result<DepositFromAllowanceResult, Errors.DepositFromAllowance>;

  /// Manages accounts and funds for users.
  /// Handles deposit, withdrawal, and consolidation operations.
  public class AccountManager(
    icrc1Ledger : ICRC1.API,
    ownPrincipal : Principal,
    log : (Principal, LogEvent) -> (),
    initialLedgerFee : Nat, // initial ledger fee
    triggerOnNotifications : Bool,
    freezeCallback : (text : Text) -> (),
    creditRegistry : CreditRegistry.CreditRegistry,
  ) {
    /// If `true` new notifications are paused.
    var notificationsOnPause_ : Bool = false;

    /// Current surcharge amount.
    /// Surcharge is a parameter representing the increment for building fees.
    var surcharge_ : Nat = 0;

    /// Manages deposit balances for each user.
    let depositRegistry = DepositRegistry.DepositRegistry(
      initialLedgerFee + surcharge_,
      freezeCallback,
    );
    let depositMap = depositRegistry.map;

    /// Total amount consolidated. Accumulated value.
    var totalConsolidated_ : Nat = 0;

    /// Total amount withdrawn. Accumulated value.
    var totalWithdrawn_ : Nat = 0;

    /// Funds credited within the class.
    /// For internal usage only.
    var credited : Nat = 0;

    /// Total funds underway for consolidation.
    var underwayFunds_ : Nat = 0;

    /// Returns `true` when new notifications are paused.
    public func notificationsOnPause() : Bool = notificationsOnPause_;

    /// Pause new notifications.
    public func pauseNotifications() = notificationsOnPause_ := true;

    /// Unpause new notifications.
    public func unpauseNotifications() = notificationsOnPause_ := false;

    /// Retrieves the current fee amount.
    public func ledgerFee() : Nat = Ledger.fee();

    /// Retrieves the current surcharge amount.
    public func surcharge() : Nat = surcharge_;

    /// Sets new surcharge amount.
    public func setSurcharge(s : Nat) {
      log(ownPrincipal, #surchargeUpdated({ old = surcharge_; new = s }));
      depositRegistry.updateFee(Ledger.fee() + s, changeCredit);
      surcharge_ := s;
    };

    /// Calculates the final fee of the specific type.
    public func fee(t : FeeType) : Nat = switch (t) {
      case (#deposit) Ledger.fee() + surcharge_;
      case (#allowance) Ledger.fee() + surcharge_;
      case (#withdrawal) Ledger.fee() + surcharge_;
    };

    var fetchFeeLock : Bool = false;

    /// Updates the fee amount based on the ICRC1 ledger.
    /// Returns the new fee, or `null` if fetching is already in progress.
    public func fetchFee() : async* ?Nat {
      if (fetchFeeLock) return null;
      fetchFeeLock := true;
      let res = await* Ledger.loadFee();
      fetchFeeLock := false;
      res;
    };

    /// Retrieves the sum of all current deposits.
    public func depositedFunds() : Nat = depositMap.sum() + underwayFunds_;

    /// Retrieves the sum of all current deposits.
    public func underwayFunds() : Nat = underwayFunds_;

    /// Retrieves the sum of all current deposits.
    public func queuedFunds() : Nat = depositMap.sum();

    /// Returns the size of the deposit registry.
    public func depositsNumber() : Nat = depositMap.size();

    /// Retrieves the sum of all successful consolidations.
    public func totalConsolidated() : Nat = totalConsolidated_;

    /// Retrieves the sum of all deductions from the main account.
    public func totalWithdrawn() : Nat = totalWithdrawn_;

    /// Retrieves the calculated balance of the main account.
    public func consolidatedFunds() : Nat = totalConsolidated_ - totalWithdrawn_;

    /// Retrieves the deposit of a principal.
    public func getDeposit(p : Principal) : ?Nat = depositMap.getOpt(p);

    func changeCredit(p : Principal, amount : Int) {
      creditRegistry.issue(#user p, amount);
      if (amount >= 0) credited += Int.abs(amount) else credited -= Int.abs(amount);
    };

    func process_deposit(p : Principal, deposit : Nat, release : ?Nat -> Int) : (Nat, Nat) {
      if (deposit <= fee(#deposit)) {
        ignore release(null);
        return (0, 0);
      };
      let delta = release(?deposit);
      if (delta < 0) freezeCallback("latestDeposit < prevDeposit on notify");
      if (delta == 0) return (0, 0);
      let inc = Int.abs(delta);

      let creditInc : Nat = switch (deposit == inc) {
        case true { deposit - fee(#deposit) };
        case false { inc };
      };

      changeCredit(p, creditInc);
      (inc, creditInc);
    };

    func updatedFee(oldFee : Nat, newFee : Nat) {
      assert oldFee != newFee;
      depositRegistry.updateFee(newFee + surcharge_, changeCredit);
      log(ownPrincipal, #feeUpdated({ old = oldFee; new = newFee }));
    };

    let Ledger = ICRC84Helper.Ledger(icrc1Ledger, ownPrincipal, initialLedgerFee, updatedFee);

    /// Notifies of a deposit and schedules consolidation process.
    /// Returns the newly detected deposit if successful.
    public func notify(p : Principal) : async* ?(Nat, Nat) {
      if (notificationsOnPause_) return null;
      let ?release = depositMap.obtainLock(p) else return null;

      let latestDeposit = switch (await* Ledger.loadDeposit(p)) {
        case (#ok x) x;
        case (#err _) {
          ignore release(null);
          return null;
        };
      };

      if (latestDeposit <= fee(#deposit)) {
        ignore release(null);
        return ?(0, 0);
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

    /// Processes allowance.
    /// `amount` - credit-side amount.
    func processAllowance(p : Principal, account : ICRC1.Account, creditAmount : Nat, expectedFee : ?Nat) : async* DepositFromAllowanceResponse {
      switch (expectedFee) {
        case null {};
        case (?f) if (f != fee(#allowance)) return #err(#BadFee { expected_fee = fee(#allowance) });
      };

      let res = await* Ledger.draw(p, account, creditAmount + fee(#allowance));

      switch (res) {
        case (#ok txid) #ok(creditAmount, txid);
        case (#err err) #err(err);
      };
    };

    /// Transfers the specified amount from the user's allowance to the service, crediting the user accordingly.
    /// This method allows a user to deposit tokens by setting up an allowance on their account with the service
    /// principal as the spender and then calling this method to transfer the allowed tokens.
    /// `amount` - credit-side amount.
    public func depositFromAllowance(p : Principal, account : ICRC1.Account, creditAmount : Nat, expectedFee : ?Nat) : async* DepositFromAllowanceResponse {
      let benefit : Nat = fee(#allowance) - Ledger.fee();

      let res = await* processAllowance(p, account, creditAmount, expectedFee);

      let event = switch (res) {
        case (#ok _) #allowanceDrawn({ amount = creditAmount });
        case (#err err) #allowanceError(err);
      };

      log(p, event);

      if (R.isOk(res)) {
        totalConsolidated_ += creditAmount + benefit;
        changeCredit(p, creditAmount);
        creditRegistry.issue(#pool, benefit);
        credited += benefit;
      };

      res;
    };

    /// Attempts to consolidate the funds for a particular principal.
    func consolidate(p : Principal, release : ?Nat -> Int) : async* TransferResponse {
      let deposit = depositMap.erase(p);
      let credit : Nat = deposit - fee(#deposit);
      let benefit : Nat = fee(#deposit) - Ledger.fee();

      let res = await* Ledger.consolidate(p, deposit);

      // log event
      let event = switch (res) {
        case (#ok _) #consolidated({
          deducted = deposit;
          credited = credit;
        });
        case (#err err) #consolidationError(err);
      };
      log(p, event);

      switch (res) {
        case (#ok _) {
          totalConsolidated_ += credit + benefit;
          creditRegistry.issue(#pool, benefit);
          credited += benefit;
          ignore release(null);
        };
        case (#err _) {
          changeCredit(p, -credit);
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
        underwayFunds_ += deposit;
        let result = await* consolidate(p, release);
        underwayFunds_ -= deposit;
        assertIntegrity();
        switch (result) {
          case (#err(#CallIcrc1LedgerError)) return;
          case (_) {};
        };
      };
    };

    /// Processes withdrawal transfer.
    func processWithdrawTransfer(p : ?Principal, to : ICRC1.Account, amount : Nat, expectedFee : ?Nat) : async* WithdrawResponse {
      let (amountToSend, amountArrived) : (Nat, Nat) = switch (p) {
        // withdrawal from pool
        case (null) {
          switch (expectedFee) {
            case null {};
            case (?f) if (f != Ledger.fee()) return #err(#BadFee { expected_fee = Ledger.fee() });
          };
          if (amount <= Ledger.fee()) return #err(#TooLowQuantity);
          amount |> (_, _ - Ledger.fee());
        };
        // withdrawal from credit
        case (?p) {
          switch (expectedFee) {
            case null {};
            case (?f) if (f != fee(#withdrawal)) return #err(#BadFee { expected_fee = fee(#withdrawal) });
          };
          if (amount <= fee(#withdrawal)) return #err(#TooLowQuantity);
          (amount - fee(#withdrawal)) : Nat |> (_ + Ledger.fee(), _);
        };
      };

      let res = await* Ledger.send(to, amountToSend);

      if (R.isOk(res)) totalWithdrawn_ += amountToSend;

      switch (res) {
        case (#ok txid) {
          if (p != null) {
            let benefit : Nat = amount - amountToSend;
            creditRegistry.issue(#pool, benefit);
            credited += benefit;
          };
          #ok(txid, amountArrived);
        };
        case (#err(#BadFee { expected_fee })) {
          #err(#BadFee { expected_fee = fee(#withdrawal) });
        };
        case (#err err) #err(err);
      };
    };

    /// Initiates a withdrawal by transferring tokens to another account.
    /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
    public func withdraw(p : ?Principal, to : ICRC1.Account, amount : Nat, expectedFee : ?Nat) : async* WithdrawResponse {
      let res = await* processWithdrawTransfer(p, to, amount, expectedFee);

      let principalToLog = switch (p) {
        case (?p) { p };
        case (null) { ownPrincipal };
      };

      let event = switch (res) {
        case (#ok _) #withdraw({ to = to; amount = amount });
        case (#err err) #withdrawalError(err);
      };

      log(principalToLog, event);

      res;
    };

    public func assertIntegrity() {
      let deposited : Int = depositMap |> _.sum() - fee(#deposit) * _.size();
      let integrityIsMaintained = consolidatedFunds() + deposited == credited;
      if (not integrityIsMaintained) {
        let values : [Text] = [
          "Balances integrity failed",
          "totalConsolidated_=" # Nat.toText(totalConsolidated_),
          "totalWithdrawn_=" # Nat.toText(totalWithdrawn_),
          "deposited=" # Int.toText(deposited),
          "credited=" # Int.toText(credited),
        ];
        freezeCallback(Text.join("; ", Iter.fromArray(values)));
      };
    };

    /// Serializes the token handler data.
    public func share() : StableData = (
      depositMap.share(),
      Ledger.fee(),
      surcharge_,
      totalConsolidated_,
      totalWithdrawn_,
    );

    /// Deserializes the token handler data.
    public func unshare(values : StableData) {
      depositMap.unshare(values.0);
      Ledger.setFee(values.1);
      surcharge_ := values.2;
      totalConsolidated_ := values.3;
      totalWithdrawn_ := values.4;
    };
  };
};
