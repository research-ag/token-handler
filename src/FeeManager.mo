import Data "Data";

module {
  public class FeeManager(data : Data.Data) {
    public func fee() : Nat = data.ledgerFee + data.surcharge;

    public func ledgerFee() : Nat = data.ledgerFee;

    public func surcharge() : Nat = data.surcharge;

    public func setSurcharge(s : Nat) {
      data.surcharge := s;
    };

    public func setLedgerFee(f : Nat) {
      data.ledgerFee := f;
    };
  };
};