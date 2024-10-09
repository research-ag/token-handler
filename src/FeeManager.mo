import Data "Data";

module {
  public class FeeManager(data : Data.Data) {
    public func fee() : Nat = data.ledgerFee + data.surcharge;

    public func ledgerFee() : Nat = data.ledgerFee;

    public func surcharge() : Nat = data.surcharge;
  };
};