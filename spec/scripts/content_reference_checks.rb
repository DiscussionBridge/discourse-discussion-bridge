# frozen_string_literal: true

# Actual stdlib reference-converter checks; no HTML5/native rendering claim.
require "json"
require_relative "../../lib/discussion_bridge/portable_content"

converter = DiscussionBridge::PortableContent
base = "https://source.example/articles/edition.html?old=1"
checks = 0
{
  "../images/figure.png" => "https://source.example/images/figure.png",
  "/audio/track.ogg" => "https://source.example/audio/track.ogg",
  "#caption" => "https://source.example/articles/edition.html?old=1#caption",
  "?edition=2&mode=all" => "https://source.example/articles/edition.html?edition=2&mode=all",
  "//media.example/video.mp4" => "https://media.example/video.mp4",
  "./a%20b.png" => "https://source.example/articles/a%20b.png",
  "" => base,
  "https://cdn.example/A%2fb?q=1&b=2" => "https://cdn.example/A%2fb?q=1&b=2",
  "mailto:author@example.test" => "mailto:author@example.test",
  "data:image/png;base64,AA==" => "data:image/png;base64,AA==",
}.each do |reference, expected|
  original = reference.dup.freeze
  actual = converter.resolve_reference(original, base)
  raise "Reference target changed: #{reference.inspect}" unless actual == expected && original == reference
  checks += 1
end

{
  "small.png 1x, ../large.png 2x" => "https://source.example/articles/small.png 1x, https://source.example/large.png 2x",
  "small.png,  large.png" => "https://source.example/articles/small.png,  https://source.example/articles/large.png",
  "data:image/png;base64,AA== 1x, /large.png 2x" => "data:image/png;base64,AA== 1x, https://source.example/large.png 2x",
  "https://cdn.example/a,b.png 1x, \n./b.png 640w" => "https://cdn.example/a,b.png 1x, \nhttps://source.example/articles/b.png 640w",
}.each do |references, expected|
  original = references.dup.freeze
  actual = converter.resolve_srcset(original, base)
  raise "Srcset target/descriptor/separator changed" unless actual == expected && original == references
  checks += 1
end

[
  -> { converter.resolve_reference("relative.png", nil) },
  -> { converter.resolve_reference("relative.png", "urn:article") },
  -> { converter.resolve_reference("relative image.png", base) },
  -> { converter.resolve_srcset("image.png 1x(foo", base) },
  -> { converter.send(:check_css_references!, "background:url(../image.png)") },
  -> { converter.send(:check_css_references!, 'background:url("https://cdn.example/a.png");x:url(') },
  -> { converter.send(:check_css_references!, '@import "../theme.css";') },
  -> { converter.send(:check_css_references!, 'background:u\\72l(../a.png)') },
].each do |operation|
  begin
    operation.call
    raise "Unsupported preparation claimed success"
  rescue converter::PreparationUnavailable
    checks += 1
  end
end
converter.send(:check_css_references!, 'color:red;background:url("https://cdn.example/a.png")')
checks += 1

[
  [%w[language-json], %w[lang-json]],
  [%w[example language-ruby], %w[example lang-ruby]],
  [%w[language-c++], %w[lang-c++]],
  [%w[lang-json], %w[lang-json]],
  [[], []],
  [%w[language-], %w[language-]],
  [%w[language-json language-ruby], %w[language-json language-ruby]],
  [%w[language-json lang-ruby], %w[language-json lang-ruby]],
  [%w[language-json language-json], %w[lang-json lang-json]],
].each do |classes, expected|
  original = classes.map(&:dup)
  classes.each(&:freeze).freeze
  actual = converter.send(:native_code_language_classes, classes)
  raise "Code language classification changed input or chose a conflicting marker" unless actual == expected && classes == original
  checks += 1
end
puts JSON.generate(checks: checks, result: "passed", limits: "actual stdlib URL/srcset and code-language token conversion only; HTML5/Discourse/native rendering UNEXECUTED")
