from __future__ import annotations

from idx_flow_scanner.providers.block_idx_evidence import (
    classify_disclosure,
    financial_filings_from_announcements,
    infer_financial_period,
    is_official_idx_url,
    official_idx_transport_candidates,
    parse_block_idx_announcement_html,
    parse_block_idx_timestamp,
)


def test_official_url_allowlist() -> None:
    assert is_official_idx_url("https://www.idx.co.id/StaticData/a.pdf")
    assert is_official_idx_url("https://block.idx.id/id/berita/pengumuman")
    assert not is_official_idx_url("http://www.idx.co.id/StaticData/a.pdf")
    assert not is_official_idx_url("https://example.com/a.pdf")
    assert not is_official_idx_url("https://idx.co.id.evil.example/a.pdf")


def test_official_transport_falls_back_to_block_host_same_path() -> None:
    original = "https://www.idx.co.id/StaticData/NewsAndAnnouncement/a.pdf?x=1"
    assert official_idx_transport_candidates(original) == [
        original,
        "https://block.idx.id/StaticData/NewsAndAnnouncement/a.pdf?x=1",
    ]
    assert official_idx_transport_candidates("https://example.com/a.pdf") == []


def test_timestamp_is_wib_point_in_time() -> None:
    value = parse_block_idx_timestamp("08 Sep 2026 00:18:04")
    assert value.isoformat() == "2026-09-08T00:18:04+07:00"


def test_parse_server_rendered_announcement_card() -> None:
    html = """
    <div class="attach-card mb-20 pb-20">
      <time class="text-small">08 Sep 2026 00:18:04</time>
      <a href="https://www.idx.co.id/StaticData/NewsAndAnnouncement/ANNOUNCEMENTSTOCK/From_EREP/202609/main.pdf">
        <h6 class="f-m-20 title">Laporan Bulanan Registrasi Pemegang Efek [<span>SWAT</span>]</h6>
      </a>
      <ul class="list-nostyle"><li><a href="https://www.idx.co.id/StaticData/NewsAndAnnouncement/ANNOUNCEMENTSTOCK/From_EREP/202609/lamp1.pdf"><small>20260907_SWAT_lamp1.pdf</small></a></li></ul>
    </div>
    """
    rows = parse_block_idx_announcement_html(html)
    assert len(rows) == 1
    row = rows[0]
    assert row["ticker"] == "SWAT"
    assert row["published_at"] == "2026-09-08T00:18:04+07:00"
    assert row["disclosure_type"] == "OWNERSHIP"
    assert row["publication_time_verified"] is True
    assert row["source_verified"] is True
    assert row["point_in_time_eligible"] is True
    assert len(row["attachment_urls"]) == 2
    assert row["attachment_urls"][1]["file_name"] == "20260907_SWAT_lamp1.pdf"


def test_nonofficial_primary_link_fails_closed() -> None:
    html = """
    <div class="attach-card"><time class="text-small">08 Sep 2026 00:18:04</time>
      <a href="https://evil.example/fake.pdf"><h6 class="title">Fakta Material [<span>TEST</span>]</h6></a>
    </div>
    """
    assert parse_block_idx_announcement_html(html) == []


def test_financial_filing_uses_announcement_publish_time_not_period_end() -> None:
    html = """
    <div class="attach-card">
      <time class="text-small">04 Mar 2026 18:44:28</time>
      <a href="https://www.idx.co.id/StaticData/NewsAndAnnouncement/ANNOUNCEMENTSTOCK/main.pdf">
        <h6 class="title">Penyampaian Laporan Keuangan Tahunan [<span>AADI</span>]</h6>
      </a>
      <ul class="list-nostyle"><li><a href="https://www.idx.co.id/Portals/0/StaticData/ListedCompanies/FinancialStatement-2025-Tahunan-AADI.xlsx"><small>FinancialStatement-2025-Tahunan-AADI.xlsx</small></a></li></ul>
    </div>
    """
    rows = parse_block_idx_announcement_html(html)
    filings = financial_filings_from_announcements(rows)
    assert len(filings) == 1
    filing = filings[0]
    assert filing["report_year"] == 2025
    assert filing["report_period"] == "AUDIT"
    assert filing["report_period_end"] == "2025-12-31"
    assert filing["published_at"] == "2026-03-04T18:44:28+07:00"
    assert filing["published_at"] != filing["report_period_end"]
    assert filing["point_in_time_eligible"] is True


def test_period_inference_and_classification() -> None:
    assert infer_financial_period("Laporan Keuangan", "FinancialStatement-2026-TW1-ABCD.xlsx") == (2026, "TW1")
    assert infer_financial_period("Laporan Keuangan Triwulan III 2026", "file.xlsx") == (2026, "TW3")
    assert classify_disclosure("Penjelasan atas Volatilitas Transaksi [ABCD]") == "VOLATILITY_EXPLANATION"
