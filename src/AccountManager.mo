import Principal "mo:base/Principal";
import Int "mo:base/Int";
import R "mo:base/Result";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";

import ICRC1 "ICRC1";
import NatMap "NatMapWithLock";
import Calls "Calls";
import CreditRegistry "CreditRegistry";

module {
  public type StableData = (
    NatMap.StableData<Principal>, // depositRegistry
    Nat, // Ledger.fee()
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
    #allowanceDrawn : { credited : Nat };
    #allowanceError : Errors.Ledger.TransferFromMin;
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
      public type TransferFromMin = TransferFrom or { #TooLowQuantity };
    };
    public type Withdraw = Ledger.TransferMin or {
      #InsufficientCredit;
      #LedgerBadFee : { expected_fee : Nat };
    };
  };

  type WithdrawResult = (transactionIndex : Nat, withdrawnAmount : Nat);
  type DepositFromAllowanceResult = (credited : Nat, txid : Nat);

  type Result<X, Y> = R.Result<X, Y>;
  public type WithdrawResponse = Result<WithdrawResult, Errors.Withdraw>;
  public type TransferResponse = Result<Nat, Errors.Ledger.Transfer>;
  public type DrawResponse = Result<Nat, Errors.Ledger.TransferFrom>;
  public type DepositFromAllowanceResponse = Result<DepositFromAllowanceResult, Errors.Ledger.TransferFromMin>;

  /// Manages accounts and funds for users.
  /// Handles deposit, withdrawal, and consolidation operations.
  public class AccountManager(
    icrc1Ledger : ICRC1.LedgerAPI,
    ownPrincipal : Principal,
    log : (Principal, LogEvent) -> (),
    initialFee : Nat,
    triggerOnNotifications : Bool,
    freezeCallback : (text : Text) -> (),
    creditRegistry : CreditRegistry.CreditRegistry,
  ) {

    let Ledger = Calls.Ledger(icrc1Ledger, ownPrincipal);

    /// If `true` new notifications are paused.
    var notificationsOnPause_ : Bool = false;

    /// Current ledger fee amount.
    Ledger.setFee(initialFee);

    /// Current surcharge amount.
    /// Surcharge is a parameter representing the increment for building fees.
    var surcharge_ : Nat = 0;

    /// Manages deposit balances for each user.
    let depositRegistry = NatMap.NatMapWithLock<Principal>(Principal.compare, Ledger.fee() + 1);

    /// Total amount consolidated. Accumulated value.
    var totalConsolidated_ : Nat = 0;

    /// Total amount withdrawn. Accumulated value.
    var totalWithdrawn_ : Nat = 0;

    /// Total funds underway for consolidation.
    var underwayFunds_ : Nat = 0;

    /// Returns `true` when new notifications are paused.
    public func notificationsOnPause() : Bool = notificationsOnPause_;

    /// Pause new notifications.
    public func pauseNotifications() = notificationsOnPause_ := true;

    /// Unpause new notifications.
    public func unpauseNotifications() = notificationsOnPause_ := false;

    // Pass through the lookup counter from depositRegistry
    // TODO: Remove later
    public func lookups() : Nat = depositRegistry.lookups();

    /// Retrieves the current fee amount.
    public func ledgerFee() : Nat = Ledger.fee();

    /// Retrieves the current surcharge amount.
    public func surcharge() : Nat = surcharge_;

    /// Sets new surcharge amount.
    public func setSurcharge(s : Nat) {
      log(ownPrincipal, #surchargeUpdated({ old = surcharge_; new = s }));
      surcharge_ := s;
    };

    /// Calculates the final fee of the specific type.
    public func fee(t : FeeType) : Nat = switch (t) {
      case (#deposit) Ledger.fee() + surcharge_;
      case (#allowance) surcharge_;
      case (#withdrawal) Ledger.fee() + surcharge_;
    };

    var fetchFeeLock : Bool = false;

    /// Updates the fee amount based on the ICRC1 ledger.
    /// Returns the new fee, or `null` if fetching is already in progress.
    public func fetchFee() : async* ?Nat {
      if (fetchFeeLock) return null;
      fetchFeeLock := true;
      let newFee = await icrc1Ledger.fee();
      fetchFeeLock := false;
      updateFee(newFee);
      ?newFee;
    };

    func recalculateBacklog(newDepositFee : Nat) {
      // update the deposit minimum depending on the new fee
      // the callback debits the principal for deposits that are removed in this step
      let depositFee = fee(#deposit);
      depositRegistry.setMinimum(newDepositFee + 1, func(p, v) = burn(p, v - depositFee));
      // adjust credit for all queued deposits
      depositRegistry.iterate(
        func(p, v) {
          if (v <= newDepositFee) freezeCallback("deposit <= newFee should have been erased in previous step");
          if (newDepositFee > depositFee) {
            burn(p, newDepositFee - depositFee);
          } else {
            issue(p, depositFee - newDepositFee);
          };
        }
      );
    };

    func updateFee(newFee : Nat) {
      if (Ledger.fee() == newFee) return;
      recalculateBacklog(newFee + surcharge_);
      log(ownPrincipal, #feeUpdated({ old = Ledger.fee(); new = newFee }));
      Ledger.setFee(newFee);
    };

    /// Retrieves the sum of all current deposits.
    public func depositedFunds() : Nat = depositRegistry.sum() + underwayFunds_;

    /// Retrieves the sum of all current deposits.
    public func underwayFunds() : Nat = underwayFunds_;

    /// Retrieves the sum of all current deposits.
    public func queuedFunds() : Nat = depositRegistry.sum();

    /// Returns the size of the deposit registry.
    public func depositsNumber() : Nat = depositRegistry.size();

    /// Retrieves the sum of all successful consolidations.
    public func totalConsolidated() : Nat = totalConsolidated_;

    /// Retrieves the sum of all deductions from the main account.
    public func totalWithdrawn() : Nat = totalWithdrawn_;

    /// Retrieves the calculated balance of the main account.
    public func consolidatedFunds() : Nat = totalConsolidated_ - totalWithdrawn_;

    /// Retrieves the deposit of a principal.
    public func getDeposit(p : Principal) : ?Nat = depositRegistry.getOpt(p);

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

      issue(p, creditInc);
      (inc, creditInc);
    };

    /// Notifies of a deposit and schedules consolidation process.
    /// Returns the newly detected deposit if successful.
    public func notify(p : Principal) : async* ?(Nat, Nat) {
      if (notificationsOnPause_) return null;
      let ?release = depositRegistry.obtainLock(p) else return null;

      let latestDeposit = try {
        await* Ledger.loadDeposit(p);
      } catch (err) {
        ignore release(null);
        throw err;
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

    // This function is async* but is guaranteed to never throw.
    func processAllowance(p : Principal, account : ICRC1.Account, amount : Nat) : async* DrawResponse {
      let res = await* Ledger.draw(p, account, amount);
      if (R.isOk(res)) {
        totalConsolidated_ += amount;
        issue(p, amount);
      };
      res;
    };

    // This function is async* but is guaranteed to never throw.
    func depositFromAllowanceRecursive(p : Principal, account : ICRC1.Account, amount : Nat, retry : Bool) : async* DepositFromAllowanceResponse {
      if (amount <= Ledger.fee()) return #err(#TooLowQuantity);

      let res = await* processAllowance(p, account, amount);

      // catch BadFee
      switch (res) {
        case (#err(#BadFee { expected_fee })) {
          updateFee(expected_fee);
          if (retry) return await* depositFromAllowanceRecursive(p, account, amount, false);
        };
        case (_) {};
      };
      // final return value
      switch (res) {
        case (#ok txid) #ok(amount, txid);
        case (#err err) #err(err);
      };
    };

    /// Transfers the specified amount from the user's allowance to the service, crediting the user accordingly.
    /// This method allows a user to deposit tokens by setting up an allowance on their account with the service
    /// principal as the spender and then calling this method to transfer the allowed tokens.
    public func depositFromAllowance(p : Principal, account : ICRC1.Account, amount : Nat) : async* DepositFromAllowanceResponse {
      let res = await* depositFromAllowanceRecursive(p, account, amount, true);
      let event = switch (res) {
        case (#ok _) #allowanceDrawn({ credited = amount });
        case (#err err) #allowanceError(err);
      };
      log(p, event);
      res;
    };

    /// Attempts to consolidate the funds for a particular principal.
    func consolidate(p : Principal, release : ?Nat -> Int) : async* TransferResponse {
      let deposit = depositRegistry.erase(p);
      let originalCredit : Nat = deposit - fee(#deposit);

      let res = await* Ledger.consolidate(p, deposit);

      // catch #BadFee
      switch (res) {
        case (#err(#BadFee { expected_fee })) updateFee(expected_fee);
        case (_) {};
      };

      // log event
      let event = switch (res) {
        case (#ok _) #consolidated({
          deducted = deposit;
          credited = originalCredit;
        });
        case (#err err) #consolidationError(err);
      };
      log(p, event);

      //
      switch (res) {
        case (#ok _) {
          totalConsolidated_ += originalCredit;
          ignore release(null);
        };
        case (#err err) {
          burn(p, originalCredit);
          ignore process_deposit(p, deposit, release);
        };
      };

      res;
    };

    /// Triggers the proccessing deposits.
    /// n - desired number of potential consolidations.
    public func trigger(n : Nat) : async* () {
      for (i in Iter.range(1, n)) {
        let ?(p, deposit, release) = depositRegistry.nextLock() else return;
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

    /// Proccesses withdrawal transfer.
    func proccessWithdrawTransfer(p : ?Principal, to : ICRC1.Account, amount : Nat, expectedFee : ?Nat) : async* WithdrawResponse {
      let (amountToSend, amountArrived) : (Nat, Nat) = switch (p) {
        // withdrawal from pool
        case (null) {
          switch (expectedFee) {
            case null {};
            case (?f) if (f != Ledger.fee()) return #err(#BadFee { expected_fee = Ledger.fee() });
          };
          if (amount <= Ledger.fee()) return #err(#TooLowQuantity);
          (amount, amount - Ledger.fee());
        };
        // withdrawal from credit
        case (?p) {
          switch (expectedFee) {
            case null {};
            case (?f) if (f != fee(#withdrawal)) return #err(#BadFee { expected_fee = fee(#withdrawal) });
          };
          if (amount <= fee(#withdrawal)) return #err(#TooLowQuantity);
          (amount - fee(#withdrawal) + Ledger.fee(), amount - fee(#withdrawal));
        };
      };

      let res = await* Ledger.send(to, amountToSend);

      switch (res) {
        case (#ok txid) #ok(txid, amountArrived);
        case (#err(#BadFee { expected_fee })) {
          updateFee(expected_fee);
          #err(#LedgerBadFee { expected_fee });
        };
        case (#err err) #err(err);
      };
    };

    /// Initiates a withdrawal by transferring tokens to another account.
    /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
    public func withdraw(p : ?Principal, to : ICRC1.Account, amount : Nat, expectedFee : ?Nat) : async* WithdrawResponse {
      totalWithdrawn_ += amount;

      let res = await* proccessWithdrawTransfer(p, to, amount, expectedFee);

      let principalToLog = switch (p) {
        case (?p) { p };
        case (null) { ownPrincipal };
      };

      let event = switch (res) {
        case (#ok _) #withdraw({ to = to; amount = amount });
        case (#err err) #withdrawalError(err);
      };

      log(principalToLog, event);

      if (R.isErr(res)) totalWithdrawn_ -= amount;

      res;
    };

    /// Increases the credit amount associated with a specific principal.
    /// For internal use only.
    func issue(p : Principal, amount : Nat) = creditRegistry.issue(#user p, amount);

    /// Deducts the credit amount associated with a specific principal.
    /// For internal use only.
    func burn(p : Principal, amount : Nat) = creditRegistry.issue(#user p, -amount);

    public func assertIntegrity() {
      let deposited : Int = depositRegistry |> _.sum() - fee(#deposit) * _.size();
      let (total, pool) = creditRegistry |> (_.totalBalance(), _.poolBalance());
      let integrityIsMaintained = consolidatedFunds() + deposited == total + pool;
      if (not integrityIsMaintained) {
        let values : [Text] = [
          "Balances integrity failed",
          "totalConsolidated_=" # Nat.toText(totalConsolidated_),
          "totalWithdrawn_=" # Nat.toText(totalWithdrawn_),
          "deposited=" # Int.toText(deposited),
          "total=" # Int.toText(total),
          "pool=" # Int.toText(pool),
        ];
        freezeCallback(Text.join("; ", Iter.fromArray(values)));
      };
    };

    /// Serializes the token handler data.
    public func share() : StableData = (
      depositRegistry.share(),
      Ledger.fee(),
      surcharge_,
      totalConsolidated_,
      totalWithdrawn_,
    );

    /// Deserializes the token handler data.
    public func unshare(values : StableData) {
      depositRegistry.unshare(values.0);
      Ledger.setFee(values.1);
      surcharge_ := values.2;
      totalConsolidated_ := values.3;
      totalWithdrawn_ := values.4;
    };
  };
};
