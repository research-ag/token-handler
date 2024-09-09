import AsyncMethodTester "mo:await-async";

module {
  type Account = { owner : Principal; subaccount : ?Subaccount };

  type Subaccount = Blob;

  type TransferArgs = {
    from_subaccount : ?Subaccount;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  type TransferResponse = {
    #Ok : Nat;
    #Err : TransferError;
  };

  type TransferFromError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  type TransferFromArgs = {
    spender_subaccount : ?Blob;
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  type TransferFromResult = {
    #Ok : Nat;
    #Err : TransferFromError;
  };

  public class MockLedger() {
    public let fee = AsyncMethodTester.AsyncVariableTester<Nat>(0, null);

    public let balance = AsyncMethodTester.AsyncVariableTester<Nat>(0, null);

    public let transfer = AsyncMethodTester.AsyncVariableTester<TransferResponse>(#Ok 42, null);
    var transfer_count_ = 0;

    public let transfer_from = AsyncMethodTester.AsyncVariableTester<TransferFromResult>(#Ok 42, null);
    var transfer_from_count_ = 0;

    public func reset_state() : async () {
      fee.reset();
      balance.reset();
      
      transfer.reset();
      transfer_count_ := 0;
      
      transfer_from.reset();
      transfer_from_count_ := 0;
    };

    public shared func icrc1_fee() : async Nat {
      await* fee.await_unlock();
      fee.get();
    };

    public shared func icrc1_balance_of(_ : Account) : async Nat {
      await* balance.await_unlock();
      balance.get();
    };

    public shared func icrc1_transfer(_ : TransferArgs) : async TransferResponse {
      await* transfer.await_unlock();
      transfer_count_ += 1;
      transfer.get();
    };

    public func transfer_count() : async Nat = async transfer_count_;

    public shared func icrc2_transfer_from(_ : TransferFromArgs) : async TransferFromResult {
      await* transfer_from.await_unlock();
      transfer_from_count_ += 1;
      transfer_from.get();
    };

    public func transfer_from_count() : async Nat = async transfer_from_count_;
  };
};
