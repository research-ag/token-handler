import Principal "mo:base/Principal";

/// This module first provides all types required to interact with an ICRC1 ledger.
/// In particular, all argument types and response types.
///
/// It furthermore defines the actor type of an ICRC1 ledger (`LedgerActor`).
/// With it a ledger actor can be created as follows:
///
/// ```
/// actor ("ryjl3-tyaaa-aaaaa-aaaba-cai") : ICRC1.LedgerActor;
/// ```
///
/// Finally it defines a type `LedgerAPI` that abstract the ledger's API from the actor.
/// It is record of shared functions.
/// This type is useful to pass the ledger's API around without having to pass around the actor.
/// It is also useful for testing purposes because one can easily mock the ledger's API without having to create an actor.
module ICRC1 {
  public type Subaccount = Blob;

  public type Account = { owner : Principal; subaccount : ?Subaccount };

  public type TransferArgs = {
    from_subaccount : ?Subaccount;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferResult = {
    #Ok : Nat;
    #Err : TransferError;
  };

  public type TransferFromError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferFromArgs = {
    spender_subaccount : ?Blob;
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferFromResult = {
    #Ok : Nat;
    #Err : TransferFromError;
  };

  // Note: The functions icrc1_fee and icrc1_balance_of in the type below are actually query functions.
  // However, for an inter-canister call it makes no difference if we declare them as query or not.
  // If we don't declare them as query then this gives us more flexbility for testing.
  public type Service = actor {
    icrc1_fee : () -> async Nat;
    icrc1_balance_of : Account -> async Nat;
    icrc1_transfer : TransferArgs -> async TransferResult;
    icrc2_transfer_from : TransferFromArgs -> async TransferFromResult;
  };

  public type API = {
    fee : shared () -> async Nat;
    balance_of : shared Account -> async Nat;
    transfer : shared TransferArgs -> async TransferResult;
    transfer_from : shared TransferFromArgs -> async TransferFromResult;
  };

  public func service(p : Principal) : Service = actor(Principal.toText(p));
  public func apiFromService(x : Service) : API = {
    fee = x.icrc1_fee;
    balance_of = x.icrc1_balance_of;
    transfer = x.icrc1_transfer;
    transfer_from = x.icrc2_transfer_from;
  };

};
