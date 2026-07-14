import ICRC1 "icrc1-api";
// import { type TokenHandler } "lib";

// A transient type for TokenHandler callbacks, shared functions, API
module {

  public type TokenHandlerContextOptions = {
    ledgerApi : ICRC1.API;
    // ownPrincipal : Principal;
    // initialFee : Nat;
    // triggerOnNotifications : Bool;
    // log : (Principal, LogEvent) -> ();
  };

  public type TokenHandlerContext = {
    api : ICRC1.API;
    // assertInvariant : () -> Bool;
    // onFeeChanged : (oldFee : Nat, newFee : Nat) -> ();
  };

  public func new(/*tokenHandler : TokenHandler, */options : TokenHandlerContextOptions) : TokenHandlerContext {
    {
      api = options.ledgerApi;
      // assertInvariant = tokenHandler.assertInvariant;
      // onFeeChanged = tokenHandler.onFeeChanged;
    };
  };

};
