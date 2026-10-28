# frozen_string_literal: true

require "rails_helper"
require "digest"

RSpec.describe DiscussionBridge::PortableContent do
  def converted_fragment(html)
    Nokogiri::HTML5.fragment(described_class.to_discourse_raw(html))
  end

  ["$x + y$", "$$x + y$$", "$$\nx + y\n$$"].each do |expression|
    it "keeps the complete plain expression #{expression.inspect} as native math source" do
      raw = described_class.to_discourse_raw("<p> #{expression} </p>")
      expect(raw).to eq("\n#{expression}\n")
      expect(raw.byteslice(1, raw.bytesize - 2).b).to eq(expression.b)
      expect(PrettyText.cook(raw)).to eq(PrettyText.cook(expression))
    end

    it "separates native math #{expression.inspect} from its surrounding HTML blocks" do
      source = "<p>Before source.</p><p> #{expression} </p><p>After source.</p>"
      actual = Nokogiri::HTML5.fragment(PrettyText.cook(described_class.to_discourse_raw(source)))
      native_reference = Nokogiri::HTML5.fragment(PrettyText.cook("Before source.\n\n#{expression}\n\nAfter source."))
      expect(actual.element_children.map(&:to_html)).to eq(native_reference.element_children.map(&:to_html))
      expect(actual.element_children.first.text).to eq("Before source.")
      expect(actual.element_children.last.text).to eq("After source.")
    end
  end

  ["A formula $x$ with surrounding prose", "$x$$", "$$x$", "$   $"].each do |text|
    it "retains paragraph markup for #{text.inspect}" do
      fragment = converted_fragment("<p>#{text}</p>")
      expect(fragment.at_css("p").text).to eq(text)
    end
  end

  it "retains Mermaid source in its existing native fenced representation" do
    raw = described_class.to_discourse_raw('<pre><code class="language-mermaid">graph TD; A--&gt;B</code></pre>')
    expect(raw).to include("```mermaid\ngraph TD; A-->B\n```")
  end

  [
    ["astro_json", 102, "10a3efcff8bb2b2ed9455c2c4dfb138427feef4881b42e4919021b20d316d402"],
    ["hugo_json", 141, "060c541c60b75d58b8fb7323103bec48b08818a4b36d0421cda297477964f56b"],
  ].each do |fixture, size, sha256|
    it "retains the observed #{fixture} code bytes and language through native cooking" do
      bytes = File.binread(File.expand_path("../fixtures/code_language/#{fixture}.txt", __dir__))
      expect(bytes.bytesize).to eq(size)
      expect(Digest::SHA256.hexdigest(bytes)).to eq(sha256)
      source = "<pre><code class=\"language-json\">#{CGI.escapeHTML(bytes.dup.force_encoding(Encoding::UTF_8))}</code></pre>"
      original = source.dup
      raw = described_class.to_discourse_raw(source)
      code = Nokogiri::HTML5.fragment(PrettyText.cook(raw)).at_css("pre > code")
      expect(code["class"].to_s.split).to include("lang-json")
      expect(code.text.b).to eq(bytes)
      expect(source).to eq(original)
      expect(raw).not_to include("```json")
    end
  end

  it "normalizes only the language marker while retaining nested code children and newlines" do
    bytes = File.binread(File.expand_path("../fixtures/code_language/astro_json.txt", __dir__))
    children = bytes.dup.force_encoding(Encoding::UTF_8).lines.map { |line| "<span class=\"token\">#{CGI.escapeHTML(line)}</span>" }.join
    source = "<pre><code class=\"language-json\">#{children}</code></pre>"
    before = Nokogiri::HTML5.fragment(source).at_css("code")
    raw = described_class.to_discourse_raw(source)
    after = Nokogiri::HTML5.fragment(raw).at_css("code")
    expect(after["class"]).to eq("lang-json")
    expect(after.children.map(&:to_html)).to eq(before.children.map(&:to_html))
    expect(after.text.b).to eq(bytes)
    cooked = Nokogiri::HTML5.fragment(PrettyText.cook(raw)).at_css("pre > code")
    expect(cooked["class"].to_s.split).to include("lang-json")
    expect(cooked.text.b).to eq(bytes)
  end

  it "retains an existing native language marker without changing its code" do
    source = '<pre><code class="lang-json">{&quot;value&quot;:&quot;&lt;tag&gt;&quot;}' + "\n\n" + '</code></pre>'
    before = Nokogiri::HTML5.fragment(source).at_css("code")
    after = converted_fragment(source).at_css("code")
    expect(after["class"]).to eq(before["class"])
    expect(after.children.map(&:to_html)).to eq(before.children.map(&:to_html))
    expect(after.text).to eq(before.text)
  end

  it "does not invent a language for unmarked code" do
    after = converted_fragment("<pre><code>literal\n\n</code></pre>").at_css("code")
    expect(after["class"]).to be_nil
    expect(after.text).to eq("literal\n\n")
  end

  ["language-json language-ruby", "language-json lang-ruby"].each do |classes|
    it "leaves ambiguous code language markers #{classes} under existing behavior" do
      source = "<pre><code class=\"#{classes}\">literal\n</code></pre>"
      after = converted_fragment(source).at_css("code")
      expect(after["class"]).to eq(classes)
      expect(after.text).to eq("literal\n")
    end
  end

  it "keeps literal backticks and escaped text rather than rebuilding generic code fences" do
    text = "literal ``` and &lt;tag&gt; &amp; value\n\n"
    after = converted_fragment("<pre><code class=\"language-json\">#{text}</code></pre>").at_css("code")
    expect(after["class"]).to eq("lang-json")
    expect(after.text).to eq("literal ``` and <tag> & value\n\n")
  end

  it "keeps the Mermaid native marker and expression on the existing fenced path" do
    raw = described_class.to_discourse_raw('<pre><code class="language-mermaid"><span>graph TD; A--&gt;B</span></code></pre>')
    expect(raw).to include("```mermaid\ngraph TD; A-->B\n```")
    code = Nokogiri::HTML5.fragment(PrettyText.cook(raw)).at_css("pre > code")
    expect(code["class"].to_s.split).to include("lang-mermaid")
    expect(code.text).to eq("graph TD; A-->B\n")
  end

  it "retains the existing Mermaid no-conversion behavior for literal fence delimiters" do
    source = '<pre><code class="language-mermaid">graph TD; ```</code></pre>'
    after = converted_fragment(source).at_css("pre > code")
    expect(after["class"]).to eq("language-mermaid")
    expect(after.text).to eq("graph TD; ```")
  end

  it "keeps a mixed formula's link destination and linked caption" do
    fragment = converted_fragment('<p>$x$ <a href="https://source.test/detail?a=1&amp;b=2">explanation</a></p>')
    expect(fragment.at_css("p a")["href"]).to eq("https://source.test/detail?a=1&b=2")
    expect(fragment.at_css("p a").text).to eq("explanation")
    expect(fragment.at_css("p").text).to include("$x$")
  end

  it "keeps image source, descriptive alternative text and caption markup" do
    fragment = converted_fragment('<p>$x$ <img src="https://source.test/diagram.png" alt="Diagram of x" title="Figure 1"><span>Figure caption</span></p>')
    image = fragment.at_css("p img")
    expect(image["src"]).to eq("https://source.test/diagram.png")
    expect(image["alt"]).to eq("Diagram of x")
    expect(image["title"]).to eq("Figure 1")
    expect(fragment.at_css("p span").text).to eq("Figure caption")
  end

  it "keeps video sources, caption track and fallback link alongside math" do
    fragment = converted_fragment('<p>$x$ <video controls poster="https://source.test/poster.png"><source src="https://source.test/video.mp4" type="video/mp4"><track kind="captions" src="https://source.test/captions.vtt" srclang="en"><a href="https://source.test/video.mp4">Video transcript and fallback</a></video></p>')
    video = fragment.at_css("p video")
    expect(video["poster"]).to eq("https://source.test/poster.png")
    expect(video.at_css("source")["src"]).to eq("https://source.test/video.mp4")
    expect(video.at_css("track")["src"]).to eq("https://source.test/captions.vtt")
    expect(video.at_css("track")["kind"]).to eq("captions")
    expect(video.at_css("a")["href"]).to eq("https://source.test/video.mp4")
    expect(video.at_css("a").text).to eq("Video transcript and fallback")
  end

  it "keeps audio source and textual fallback alongside math" do
    fragment = converted_fragment('<p>$x$ <audio controls><source src="https://source.test/audio.ogg" type="audio/ogg"><a href="https://source.test/transcript">Audio transcript</a></audio></p>')
    expect(fragment.at_css("p audio source")["src"]).to eq("https://source.test/audio.ogg")
    expect(fragment.at_css("p audio a")["href"]).to eq("https://source.test/transcript")
    expect(fragment.at_css("p audio a").text).to eq("Audio transcript")
  end

  it "keeps a provider embed as submitted without granting native provider support" do
    fragment = converted_fragment('<p>$x$ <iframe src="https://provider.test/embed/1" title="Video explanation"></iframe></p>')
    expect(fragment.at_css("p iframe")["src"]).to eq("https://provider.test/embed/1")
    expect(fragment.at_css("p iframe")["title"]).to eq("Video explanation")
  end

  it "keeps a math caption in its figure context" do
    fragment = converted_fragment('<figure><img src="https://source.test/figure.png" alt="Figure"><figcaption><p>$x$</p></figcaption></figure>')
    expect(fragment.at_css("figure figcaption p").text).to eq("$x$")
    expect(fragment.at_css("figure img")["alt"]).to eq("Figure")
  end

  it "keeps meaning-bearing paragraph attributes and inline code" do
    fragment = converted_fragment('<p id="equation" lang="en">$x$ <code>literal()</code></p>')
    expect(fragment.at_css("p")["id"]).to eq("equation")
    expect(fragment.at_css("p")["lang"]).to eq("en")
    expect(fragment.at_css("p code").text).to eq("literal()")
  end

  it "keeps original article-relative navigation, media, captions and fallback targets" do
    html = '<figure><video poster="../poster.png" controls><source src="./film.mp4"><track src="/captions/en.vtt" kind="captions"><a href="../transcript#part">Transcript</a></video><figcaption>Figure caption</figcaption></figure><p><a href="#detail">Detail</a><audio src="//media.test/audio.ogg"></audio></p>'
    original = html.dup
    raw = described_class.to_discourse_raw(html, source_url: "https://source.test/articles/edition/")
    fragment = Nokogiri::HTML5.fragment(raw)
    expect(fragment.at_css("video")["poster"]).to eq("https://source.test/articles/poster.png")
    expect(fragment.at_css("video source")["src"]).to eq("https://source.test/articles/edition/film.mp4")
    expect(fragment.at_css("track")["src"]).to eq("https://source.test/captions/en.vtt")
    expect(fragment.at_css("video a")["href"]).to eq("https://source.test/articles/transcript#part")
    expect(fragment.at_css("figcaption").text).to eq("Figure caption")
    expect(fragment.at_css("p a")["href"]).to eq("https://source.test/articles/edition/#detail")
    expect(fragment.at_css("audio")["src"]).to eq("https://media.test/audio.ogg")
    expect(html).to eq(original)
  end

  it "retains responsive image targets and descriptors against the captured article URL" do
    raw = described_class.to_discourse_raw('<picture><source srcset="../small.webp 1x, ../large.webp 2x"><img src="fallback.png" alt="Diagram"></picture>', source_url: "https://source.test/edition/article/")
    fragment = Nokogiri::HTML5.fragment(raw)
    expect(fragment.at_css("source")["srcset"]).to eq("https://source.test/edition/small.webp 1x, https://source.test/edition/large.webp 2x")
    expect(fragment.at_css("img")["src"]).to eq("https://source.test/edition/article/fallback.png")
    expect(fragment.at_css("img")["alt"]).to eq("Diagram")
  end

  it "preserves unformatted text and nontext markup without a prose eligibility gate" do
    expect(described_class.to_discourse_raw("Unformatted source text")).to eq("Unformatted source text")
    fragment = Nokogiri::HTML5.fragment(described_class.to_discourse_raw('<img src="https://source.test/image.png" alt="">'))
    expect(fragment.at_css("img")["src"]).to eq("https://source.test/image.png")
  end

  it "reports missing captured context rather than silently retargeting a relative link" do
    expect { described_class.to_discourse_raw('<a href="relative">Article</a>') }.to raise_error(described_class::PreparationUnavailable)
  end

  it "reports unsupported CSS and document-base target conversion as Bridge limitations" do
    ['<p style="background:url(../image.png)">Article</p>', '<style>@import "../theme.css";</style>', '<base href="https://other.test/"><a href="relative">Article</a>'].each do |html|
      expect { described_class.to_discourse_raw(html, source_url: "https://source.test/article/") }.to raise_error(described_class::PreparationUnavailable)
    end
  end
end
