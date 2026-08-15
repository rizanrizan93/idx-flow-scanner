import pandas as pd
import pytest
from idx_flow_scanner.data import normalize_broker_summary


def test_broker_contract_rejects_missing_columns():
    with pytest.raises(ValueError):
        normalize_broker_summary(pd.DataFrame({"ticker":["ELSA"]}))
