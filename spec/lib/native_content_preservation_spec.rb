# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscussionBridge::NativeContentPreservation do
  def compare(source, cooked, **options)
    described_class.verify!(source_html: source, cooked_html: cooked,
      source_url: "https://source.example/articles/edition/", native_url: "https://forum.example/t/topic/123", **options)
  end

  def losses(source, cooked)
    compare(source, cooked)
    raise "Expected observed structural/data loss"
  rescue described_class::Loss => error
    error.losses
  end

  [nil, "", "\xFF".b].each do |unavailable|
    it "distinguishes required native article output unavailable #{unavailable.inspect} from observed loss" do
      expect { compare("Unformatted source remains valid", unavailable) }.to raise_error(described_class::ArticleUnavailable) { |error|
        expect(error.diagnostic_kind).to eq("article_unavailable")
        expect(error.losses).to include(hash_including("kind" => "required_native_article_unavailable"))
      }
    end
  end

  it "reports a dependency article-parser failure as preparation unavailable" do
    allow(Nokogiri::HTML5).to receive(:fragment).and_raise(ArgumentError, "PARSER_ERROR_BODY_SENTINEL")
    expect { compare("Unformatted source", "Native output") }.to raise_error(DiscussionBridge::PortableContent::PreparationUnavailable) { |error|
      expect(error.diagnostic_code).to eq("native_article_parser_unavailable")
      expect(error.message).not_to include("PARSER_ERROR_BODY_SENTINEL")
    }
  end

  it "identifies actual removed script structure and nonempty body without logging program bytes" do
    result = losses('<script>PROGRAM_BODY_SENTINEL()</script>', "<p>Remaining article</p>")
    expect(result.map { |row| row.fetch("kind") }).to include("script_structure_removed_or_changed", "script_nonempty_data_removed_or_changed")
    expect(JSON.generate(result)).not_to include("PROGRAM_BODY_SENTINEL")
  end

  it "identifies removed inert data separately without labeling it executable" do
    result = losses('<script type="application/json">{"article_data":"INERT_DATA_SENTINEL"}</script>', "<p>Remaining article</p>")
    expect(result).to include(hash_including("kind" => "script_nonempty_data_removed_or_changed"))
    expect(JSON.generate(result)).not_to include("INERT_DATA_SENTINEL", "executable")
  end

  it "identifies an actually missing nonempty handler while its control survives" do
    result = losses('<button onclick="PROGRAM_HANDLER_SENTINEL()">Open</button>', '<button>Open</button>')
    expect(result).to include(hash_including("kind" => "nonempty_on_attribute_removed_or_changed", "element" => "button", "attribute" => "onclick"))
    expect(JSON.generate(result)).not_to include("PROGRAM_HANDLER_SENTINEL")
  end

  it "does not mistake the same handler moved onto another identified control for preservation" do
    source = '<button id="first" onclick="doSomething()">First</button><button id="second">Second</button>'
    cooked = '<button id="first">First</button><button id="second" onclick="doSomething()">Second</button>'
    expect(losses(source, cooked)).to include(hash_including("kind" => "nonempty_on_attribute_removed_or_changed"))
    expect { compare('<button onclick="doSomething()">Open</button>', '<button id="native-added" onclick="doSomething()">Open</button>') }.not_to raise_error
  end

  it "reports actual form/control and entered-data removal" do
    result = losses('<form action="/submit"><input name="choice"><textarea>ARTICLE_DATA_SENTINEL</textarea></form>', '<p>ARTICLE_DATA_SENTINEL</p>')
    expect(result).to include(hash_including("kind" => "control_structure_removed", "element" => "form"))
    expect(result).to include(hash_including("kind" => "control_nonempty_data_removed_or_changed", "element" => "textarea"))
  end

  it "detects a control disabled by actual conversion" do
    result = losses('<input name="choice">', '<input name="choice" disabled>')
    expect(result).to include(hash_including("kind" => "control_state_changed", "attribute" => "disabled"))
  end

  it "does not treat escaped displayed program code as an actual script or handler" do
    source = '<pre><code>&lt;script&gt;example()&lt;/script&gt; &lt;button onclick="example()"&gt;</code></pre>'
    expect { compare(source, source) }.not_to raise_error
  end

  it "accepts actually retained script/data rather than inferring removal from Core defaults" do
    source = '<script type="application/json">{"data":1}</script><button onclick="doSomething()">Open</button>'
    expect { compare(source, source) }.not_to raise_error
  end

  it "accepts supported direct-src to child-source player normalization with preserved target" do
    source = '<video controls src="../video.mp4"></video>'
    cooked = '<video controls><source src="https://source.example/articles/video.mp4"></video>'
    expect { compare(source, cooked) }.not_to raise_error
  end

  it "accepts retained video/audio captions and source targets" do
    source = '<video controls poster="https://source.example/poster.png"><source src="https://source.example/video.mp4" type="video/mp4"><track kind="captions" src="https://source.example/en.vtt" srclang="en"></video><audio controls><source src="https://source.example/audio.ogg"></audio>'
    expect { compare(source, source) }.not_to raise_error
  end

  it "reports an actually removed track and player source" do
    source = '<video controls><source src="https://source.example/video.mp4"><track src="https://source.example/en.vtt" kind="captions"></video>'
    result = losses(source, '<video controls></video>')
    expect(result).to include(hash_including("kind" => "media_source_removed_or_changed"), hash_including("kind" => "media_track_removed_or_changed"))
  end

  it "keeps genuine native disclosures despite additional native wrapper attributes" do
    source = '<details open><summary>More</summary><p>Article</p></details>'
    cooked = '<details open class="elided"><summary>More</summary><p>Article</p></details>'
    expect { compare(source, cooked) }.not_to raise_error
  end

  it "retains actual native component data without selecting a provider or execution policy" do
    source = '<div class="video-placeholder-container" data-video-src="https://source.example/video.mp4"><video controls><source src="https://source.example/video.mp4"></video></div>'
    expect { compare(source, source) }.not_to raise_error
  end

  it "reports nonempty custom component data loss without exposing its value" do
    result = losses('<x-native data-state="ARTICLE_DATA_SENTINEL"></x-native>', '<div></div>')
    expect(result).to include(hash_including("kind" => "nonempty_attribute_data_removed_or_changed", "element" => "x-native", "attribute" => "data-state"))
    expect(JSON.generate(result)).not_to include("ARTICLE_DATA_SENTINEL")
  end

  it "does not mistake the owned generated link marker for authored article data" do
    source = '<p>Article prefix</p><p data-discussionbridge-generated="read-more"><a href="https://source.example/article/">Read More</a></p>'
    cooked = '<p>Article prefix</p><p><a href="https://source.example/article/">Read More</a></p>'
    expect { compare(source, cooked, owned_generated_link: true) }.not_to raise_error
    expect(losses(source, cooked)).to include(hash_including("kind" => "nonempty_attribute_data_removed_or_changed"))
  end
end
