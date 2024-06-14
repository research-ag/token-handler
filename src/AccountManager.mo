import Principal "mo:base/Principal";
import Int "mo:base/Int";
import R "mo:base/Result";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Result "mo:base/Result";

import ICRC1 "ICRC1";
import NatMap "NatMapWithLock";
import Util "util";

module {
  public type StableData = (
    NatMap.StableData<Principal>, // depositRegistry
    Nat, // ledgerFee_
    Nat, // definedDepositFee_
    Nat, // definedWithdrawalFee_
    Nat, // definedDepositMinimum_
    Nat, // definedWithdrawalMinimum_
    Nat, // totalConsolidated_
    Nat, // totalWithdrawn_
    Nat, // totalCredited
    Nat, // totalDebited
  );

  public type LogEvent = {
    #feeUpdated : { old : Nat; new : Nat };
    #depositFeeUpdated : { old : Nat; new : Nat };
    #withdrawalFeeUpdated : { old : Nat; new : Nat };
    #depositMinimumUpdated : { old : Nat; new : Nat };
    #withdrawalMinimumUpdated : { old : Nat; new : Nat };
    #newDeposit : Nat;
    #consolidated : { deducted : Nat; credited : Nat };
    #consolidationError : Errors.Ledger.TransferMin;
    #withdraw : { to : ICRC1.Account; amount : Nat };
    #withdrawalError : Errors.Withdraw;
    #allowanceDrawn : { credited : Nat };
    #allowanceError : Errors.Ledger.TransferFromMin;
  };

  public type MinimumType = {
    #deposit;
    #withdrawal;
  };

  public type FeeType = {
    #deposit;
    #withdrawal;
  };

  module Errors {
    public module Ledger {
      public type Transfer = ICRC1.TransferError or { #CallIcrc1LedgerError };
      public type TransferFrom = ICRC1.TransferFromError or { #CallIcrc1LedgerError };
      public type TransferMin = Transfer or { #TooLowQuantity };
      public type TransferFromMin = TransferFrom or { #TooLowQuantity };
    };
    public type Withdraw = Ledger.TransferMin or { #InsufficientCredit };
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
    issue_ : (Principal, Int) -> (),
  ) {

    /// If `true` new notifications are paused.
    var notificationsOnPause_ : Bool = false;

    /// Current ledger fee amount.
    var ledgerFee_ : Nat = initialFee;

    /// Admin-defined deposit fee.
    /// Final fee: max(admin_defined_fee, fee).
    var definedDepositFee_ : Nat = 0;

    /// Admin-defined withdrawal fee.
    /// Final fee: max(admin_defined_fee, fee).
    var definedWithdrawalFee_ : Nat = 0;

    /// Manages deposit balances for each user.
    let depositRegistry = NatMap.NatMapWithLock<Principal>(Principal.compare, ledgerFee_ + 1);

    /// Admin-defined deposit minimum.
    /// Can be less then the current fee.
    /// Final minimum: max(admin_defined_min, fee + 1).
    var definedDepositMinimum_ : Nat = 0;

    /// Admin-defined withdrawal minimum.
    /// Can be less then the current fee.
    /// Final minimum: max(admin_defined_min, fee + 1).
    var definedWithdrawalMinimum_ : Nat = 0;

    /// Total amount consolidated. Accumulated value.
    var totalConsolidated_ : Nat = 0;

    /// Total amount withdrawn. Accumulated value.
    var totalWithdrawn_ : Nat = 0;

    /// Total funds underway for consolidation.
    var underwayFunds_ : Nat = 0;

    /// Total funds credited within deposit tracking and consolidation.
    /// Accumulated value.
    var totalCredited : Nat = 0;

    /// Total funds debited within deposit tracking and consolidation.
    /// Accumulated value.
    var totalDebited : Nat = 0;

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
    public func ledgerFee() : Nat = ledgerFee_;

    /// Retrieves the admin-defined fee of the specific type.
    public func definedFee(t : FeeType) : Nat = switch (t) {
      case (#deposit) definedDepositFee_;
      case (#withdrawal) definedWithdrawalFee_;
    };

    /// Calculates the final fee of the specific type.
    public func fee(t : FeeType) : Nat = Nat.max(definedFee(t), ledgerFee_);

    // Checks if the fee has changed compared to old value and log if yes.
    func logFee(t : FeeType, old : Nat) {
      let new = fee(t);
      if (old == new) return;
      switch (t) {
        case (#deposit) log(ownPrincipal, #depositFeeUpdated({ old = old; new = new }));
        case (#withdrawal) log(ownPrincipal, #withdrawalFeeUpdated({ old = old; new = new }));
      };
    };

    /// Defines the admin-defined fee of the specific type.
    public func setFee(t : FeeType, value : Nat) {
      if (value == definedFee(t)) return;
      recalculateBacklog(Nat.max(value, ledgerFee_));
      let old = fee(t);
      let oldMinimum = minimum(t);
      switch (t) {
        case (#deposit) definedDepositFee_ := value;
        case (#withdrawal) definedWithdrawalFee_ := value;
      };
      logFee(t, old);
      logMinimum(t, oldMinimum);
    };

    /// Retrieves the admin-defined minimum of the specific type.
    public func definedMinimum(t : MinimumType) : Nat = switch (t) {
      case (#deposit) definedDepositMinimum_;
      case (#withdrawal) definedWithdrawalMinimum_;
    };

    /// Calculates the final minimum of the specific type.
    public func minimum(t : MinimumType) : Nat = Nat.max(definedMinimum(t), fee(t) + 1);

    // check if the minimum has changed compared to old value and log if yes
    func logMinimum(t : MinimumType, old : Nat) {
      let new = minimum(t);
      if (old == new) return;
      switch (t) {
        case (#deposit) log(ownPrincipal, #depositMinimumUpdated({ old = old; new = new }));
        case (#withdrawal) log(ownPrincipal, #withdrawalMinimumUpdated({ old = old; new = new }));
      };
    };

    /// Defines the admin-defined minimum of the specific type.
    public func setMinimum(t : MinimumType, min : Nat) {
      if (min == definedMinimum(t)) return;
      let old = minimum(t);
      switch (t) {
        case (#deposit) definedDepositMinimum_ := min;
        case (#withdrawal) definedWithdrawalMinimum_ := min;
      };
      logMinimum(t, old);
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
      if (ledgerFee_ == newFee) return;
      let minimumPrev = (minimum(#deposit), minimum(#withdrawal));
      let feePrev = (fee(#deposit), fee(#withdrawal));

      recalculateBacklog(Nat.max(definedFee(#deposit), newFee));

      log(ownPrincipal, #feeUpdated({ old = ledgerFee_; new = newFee }));
      ledgerFee_ := newFee;

      // log possible changes in deposit/withdrawal minima
      logMinimum(#deposit, minimumPrev.0);
      logMinimum(#withdrawal, minimumPrev.1);

      // log possible changes in deposit/withdrawal fee
      logFee(#deposit, feePrev.0);
      logFee(#withdrawal, feePrev.1);
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
        await* loadDeposit(p);
      } catch (err) {
        ignore release(null);
        throw err;
      };

      if (latestDeposit < minimum(#deposit)) {
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
    func drawFromAllowance(p : Principal, account : ICRC1.Account, amount : Nat) : async* DrawResponse {
      try {
        R.fromUpper(await icrc1Ledger.transfer_from({
          spender_subaccount = ?Util.toSubaccount(p);
          from = account;
          to = { owner = ownPrincipal; subaccount = null };
          amount = amount;
          fee = ?ledgerFee_;
          memo = null;
          created_at_time = null;
        }));
      } catch (_) {
        #err(#CallIcrc1LedgerError);
      };
    };

    // This function is async* but is guaranteed to never throw.
    func processAllowance(p : Principal, account : ICRC1.Account, amount : Nat) : async* DrawResponse {
      let res = await* drawFromAllowance(p, account, amount);
      if (R.isOk(res)) {
        totalConsolidated_ += amount;
        issue(p, amount);
      };
      res;
    };

    // This function is async* but is guaranteed to never throw.
    func depositFromAllowanceRecursive(p : Principal, account : ICRC1.Account, amount : Nat, retry : Bool) : async* DepositFromAllowanceResponse {
      if (amount < minimum(#deposit)) return #err(#TooLowQuantity);

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

    /// Processes the consolidation transfer for a principal.
    func processConsolidationTransfer(p : Principal, deposit : Nat) : async* TransferResponse {
      let transferAmount : Nat = deposit - ledgerFee_;

      let transferResult = try {
        R.fromUpper(await icrc1Ledger.transfer({
          from_subaccount = ?Util.toSubaccount(p);
          to = { owner = ownPrincipal; subaccount = null };
          amount = transferAmount;
          fee = ?ledgerFee_;
          memo = null;
          created_at_time = null;
        }));
      } catch (_) {
        #err(#CallIcrc1LedgerError);
      };

      transferResult;
    };

    /// Attempts to consolidate the funds for a particular principal.
    func consolidate(p : Principal, release : ?Nat -> Int) : async* TransferResponse {
      let deposit = depositRegistry.erase(p);
      let originalCredit : Nat = deposit - fee(#deposit);

      let res = await* processConsolidationTransfer(p, deposit);

      // catch #BadFee
      switch (res) {
        case (#err(#BadFee { expected_fee })) updateFee(expected_fee);
        case (_) {};
      };

      // log event
      let event = switch (res) {
        case (#ok _) #consolidated({ deducted = deposit; credited = originalCredit });
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

    /// Processes the transfer of funds for withdrawal.
    func processWithdrawTransfer(to : ICRC1.Account, amount : Nat) : async* TransferResponse {
      try {
        R.fromUpper(await icrc1Ledger.transfer({
          from_subaccount = null;
          to = to;
          amount = Int.abs(amount - ledgerFee_);
          fee = ?ledgerFee_;
          memo = null;
          created_at_time = null;
        }));
      } catch (err) {
        #err(#CallIcrc1LedgerError);
      };
    };

    func withdrawRecursive(to : ICRC1.Account, amount : Nat, retry : Bool) : async* WithdrawResponse {
      if (amount < minimum(#withdrawal)) return #err(#TooLowQuantity);

      let res = await* processWithdrawTransfer(to, amount);

      // catch BadFee
      switch (res) {
        case (#err(#BadFee { expected_fee })) {
          updateFee(expected_fee);
          if (retry) return await* withdrawRecursive(to, amount, false);
        };
        case (_) {};
      };
      // final return value
      switch (res) {
        case (#ok txid) #ok(txid, amount - fee(#withdrawal));
        case (#err err) #err(err);
      };
    };

    /// Initiates a withdrawal by transferring tokens to another account.
    /// Returns ICRC1 transaction index and amount of transferred tokens (fee excluded).
    public func withdraw(to : ICRC1.Account, amount : Nat) : async* WithdrawResponse {
      totalWithdrawn_ += amount;

      let res = await* withdrawRecursive(to, amount, true);

      let event = switch (res) {
        case (#ok _) #withdraw({ to = to; amount = amount });
        case (#err err) #withdrawalError(err);
      };
      log(ownPrincipal, event);

      if (R.isErr(res)) totalWithdrawn_ -= amount;

      res
    };

    /// Increases the credit amount associated with a specific principal.
    /// For internal use only - within deposit tracking and consolidation.
    func issue(p : Principal, amount : Nat) {
      totalCredited += amount;
      issue_(p, amount);
    };

    /// Deducts the credit amount associated with a specific principal.
    /// For internal use only - within deposit tracking and consolidation.
    func burn(p : Principal, amount : Nat) {
      totalDebited += amount;
      issue_(p, -amount);
    };

    public func assertIntegrity() {
      let deposited : Int = depositRegistry.sum() - fee(#deposit) * depositRegistry.size(); // deposited funds with fees subtracted
      if (totalCredited != totalConsolidated_ + deposited + totalDebited) {
        let values : [Text] = [
          "Balances integrity failed",
          "totalCredited=" # Nat.toText(totalCredited),
          "totalConsolidated_=" # Nat.toText(totalConsolidated_),
          "deposited=" # Int.toText(deposited),
          "totalDebited=" # Nat.toText(totalDebited),
        ];
        freezeCallback(Text.join("; ", Iter.fromArray(values)));
        return;
      };

    };

    /// Fetches actual deposit for a principal from the ICRC1 ledger.
    func loadDeposit(p : Principal) : async* Nat {
      await icrc1Ledger.balance_of({
        owner = ownPrincipal;
        subaccount = ?Util.toSubaccount(p);
      });
    };

    /// Serializes the token handler data.
    public func share() : StableData = (
      depositRegistry.share(),
      ledgerFee_,
      definedDepositFee_,
      definedWithdrawalFee_,
      definedDepositMinimum_,
      definedWithdrawalMinimum_,
      totalConsolidated_,
      totalWithdrawn_,
      totalCredited,
      totalDebited,
    );

    /// Deserializes the token handler data.
    public func unshare(values : StableData) {
      depositRegistry.unshare(values.0);
      ledgerFee_ := values.1;
      definedDepositFee_ := values.2;
      definedWithdrawalFee_ := values.3;
      definedDepositMinimum_ := values.4;
      definedWithdrawalMinimum_ := values.5;
      totalConsolidated_ := values.6;
      totalWithdrawn_ := values.7;
      totalCredited := values.8;
      totalDebited := values.9;
    };
  };
};
