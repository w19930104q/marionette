require "../spec_helper"

# A fake WebDriver that returns canned responses instead of talking to a
# real browser driver over HTTP. Responses can be queued per command; the
# last queued response is repeated for subsequent calls.
class FakeWebDriver < Marionette::WebDriver
  getter calls = [] of String

  @responses = {} of String => Array(JSON::Any)
  @errors = {} of String => Exception

  def initialize
    super(:chrome, URI.parse("http://localhost:4499"), HTTP::Client.new("localhost", 4499))
  end

  # Queue a response value for the given command. `value` is wrapped in
  # a `{"value": ...}` envelope like a real driver would return.
  def push(command : String, value)
    (@responses[command] ||= [] of JSON::Any) << JSON.parse({"value" => value}.to_json)
  end

  # Replace the queued responses for the given command with a single one.
  def set(command : String, value)
    @responses[command] = [JSON.parse({"value" => value}.to_json)]
  end

  # Make the given command raise the given error.
  def push_error(command : String, ex : Exception)
    @errors[command] = ex
  end

  # Stop raising for the given command.
  def clear_error(command : String)
    @errors.delete(command)
  end

  def execute(command : String, params = {} of String => String)
    @calls << command

    if ex = @errors[command]?
      raise ex
    end

    if queue = @responses[command]?
      return queue.shift if queue.size > 1
      return queue.first unless queue.empty?
    end

    JSON.parse(%({"value": null}))
  end
end

# A service whose "driver process" is just a long-running sleep, so stop
# semantics can be tested against a real OS process. It listens on its
# port so `open?`/`closed?` behave like they would for a real driver.
class FakeService < Marionette::Service
  @server : TCPServer? = nil

  def start
    @server = TCPServer.new(@host, @port)
    @process = Process.new("sleep", ["60"])
  end

  def stop
    @server.try(&.close)
    @server = nil
    super
  end
end

private def element_refs(ids : Array(String), w3c : Bool)
  key = w3c ? Marionette::Element::ELEMENT_KEY : "ELEMENT"
  ids.map { |id| {key => id} }
end

private def fake_session(driver, w3c = false, service = nil)
  Marionette::Session.new(
    driver,
    id: "FAKE_SESSION_ID",
    type: :local,
    capabilities: {} of String => JSON::Any,
    service: service,
    w3c: w3c
  )
end

Spectator.describe "Marionette::Session batch element queries" do
  describe "#find_elements" do
    it "returns all elements for legacy (non-W3C) drivers" do
      driver = FakeWebDriver.new
      driver.push("FindElements", element_refs(%w[el-1 el-2 el-3], w3c: false))
      session = fake_session(driver)

      elements = session.find_elements(".row")

      expect(elements.size).to eq(3)
      expect(elements.map(&.id)).to eq(%w[el-1 el-2 el-3])
    end

    it "returns all elements for W3C drivers" do
      driver = FakeWebDriver.new
      driver.push("FindElements", element_refs(%w[el-1 el-2], w3c: true))
      session = fake_session(driver, w3c: true)

      elements = session.find_elements(".row")

      expect(elements.map(&.id)).to eq(%w[el-1 el-2])
    end

    it "returns an empty array when nothing matches" do
      driver = FakeWebDriver.new
      driver.push("FindElements", [] of JSON::Any)
      session = fake_session(driver)

      expect(session.find_elements(".missing")).to be_empty
    end

    it "returns all children when a parent element is given" do
      driver = FakeWebDriver.new
      driver.push("FindChildElements", element_refs(%w[cell-1 cell-2], w3c: false))
      session = fake_session(driver)
      parent = Marionette::Element.new(session, "row-1")

      elements = session.find_elements(".cell", parent: parent)

      expect(elements.map(&.id)).to eq(%w[cell-1 cell-2])
      expect(driver.calls).to contain("FindChildElements")
    end
  end

  describe "#wait_for_elements" do
    it "keeps waiting while the result set is empty" do
      driver = FakeWebDriver.new
      driver.push("FindElements", [] of JSON::Any)
      driver.push("FindElements", [] of JSON::Any)
      driver.push("FindElements", element_refs(%w[el-1 el-2], w3c: false))
      session = fake_session(driver)

      elements = session.wait_for_elements(".row", timeout: 5.seconds, poll_time: 10.milliseconds)

      expect(elements.map(&.id)).to eq(%w[el-1 el-2])
      expect(driver.calls.count("FindElements")).to eq(3)
    end

    it "raises Error::Timeout on timeout without stopping the session" do
      service = FakeService.new(:chrome)
      service.start
      driver = FakeWebDriver.new
      driver.push("FindElements", [] of JSON::Any)
      session = fake_session(driver, service: service)

      expect_raises(Marionette::Error::Timeout) do
        session.wait_for_elements(".row", timeout: 100.milliseconds, poll_time: 10.milliseconds)
      end

      # The browser must not have been stopped by the timeout ...
      expect(driver.calls).to_not contain("Quit")
      expect(session.running?).to be_true

      # ... and the session stays usable for the remaining rows.
      driver.set("FindElements", element_refs(%w[el-1], w3c: false))
      expect(session.find_elements(".row").map(&.id)).to eq(%w[el-1])

      session.stop
    end
  end

  describe "#wait_for_element" do
    it "raises Error::Timeout on timeout without stopping the session" do
      driver = FakeWebDriver.new
      driver.push_error("FindElement", Marionette::Error::NoSuchElement.new)
      session = fake_session(driver)

      expect_raises(Marionette::Error::Timeout) do
        session.wait_for_element(".row", timeout: 100.milliseconds, poll_time: 10.milliseconds)
      end

      expect(driver.calls).to_not contain("Quit")

      # The session stays usable after the failed wait.
      driver.clear_error("FindElement")
      driver.push("FindElement", {"ELEMENT" => "el-9"})
      expect(session.find_element(".row").try(&.id)).to eq("el-9")
    end
  end
end

Spectator.describe "Marionette::ActionBuilder#release" do
  it "moves to the selector and releases the button" do
    driver = FakeWebDriver.new
    session = fake_session(driver)
    builder = Marionette::ActionBuilder.new(session: session)

    builder.release("#row")

    expect(builder.actions.map(&.[0])).to eq(%w[MoveTo MouseUp])
  end

  it "supports release_right with a selector" do
    driver = FakeWebDriver.new
    session = fake_session(driver)
    builder = Marionette::ActionBuilder.new(session: session)

    builder.release_right("#row")

    expect(builder.actions.map(&.[0])).to eq(%w[MoveTo MouseUp])
  end

  it "supports drag_and_drop between two elements" do
    driver = FakeWebDriver.new
    session = fake_session(driver)
    builder = Marionette::ActionBuilder.new(session: session)
    source = Marionette::Element.new(session, "el-1")
    dest = Marionette::Element.new(session, "el-2")

    builder.drag_and_drop(source, dest)

    expect(builder.actions.map(&.[0])).to eq(%w[MoveTo MouseDown MoveTo MouseUp])
  end
end

Spectator.describe "Marionette::Session#stop" do
  it "shuts down the driver process and is idempotent" do
    service = FakeService.new(:chrome)
    service.start
    process = service.process

    driver = FakeWebDriver.new
    driver.push("Quit", nil)
    session = fake_session(driver, service: service)

    expect(session.running?).to be_true

    session.stop

    # The driver process is confirmed dead after the first stop.
    expect(process.not_nil!.terminated?).to be_true
    expect(session.stopped?).to be_true
    expect(driver.calls.count("Quit")).to eq(1)

    # Repeated stops are a no-op and don't raise.
    session.stop
    service.stop
    expect(driver.calls.count("Quit")).to eq(1)
  end

  it "is idempotent without a service" do
    driver = FakeWebDriver.new
    driver.push("Quit", nil)
    session = fake_session(driver)

    session.stop
    session.stop

    expect(driver.calls.count("Quit")).to eq(1)
  end

  it "still stops the service when the session is already gone" do
    service = FakeService.new(:chrome)
    service.start
    process = service.process

    driver = FakeWebDriver.new
    driver.push_error("Quit", Marionette::Error::InvalidSessionId.new)
    session = fake_session(driver, service: service)

    session.stop

    expect(process.not_nil!.terminated?).to be_true
    expect(session.stopped?).to be_true
  end
end
