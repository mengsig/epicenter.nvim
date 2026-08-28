local easing = require("epicenter.ui.easing")

describe("easing", function()
  local curves = { "linear", "out_cubic", "in_cubic", "in_out_cubic", "out_quart" }

  it("pins both endpoints", function()
    for _, name in ipairs(curves) do
      expect.near(easing[name](0), 0, 1e-9, name .. "(0)")
      expect.near(easing[name](1), 1, 1e-9, name .. "(1)")
    end
  end)

  it("is monotonic and stays inside [0,1]", function()
    for _, name in ipairs(curves) do
      local previous = -1
      for step = 0, 100 do
        local v = easing[name](step / 100)
        expect.truthy(v >= previous - 1e-9, name .. " went backwards at t=" .. step / 100)
        expect.truthy(v >= 0 and v <= 1, name .. " left [0,1] at t=" .. step / 100)
        previous = v
      end
    end
  end)

  it("clamps out-of-range input", function()
    for _, name in ipairs(curves) do
      expect.near(easing[name](-5), 0, 1e-9)
      expect.near(easing[name](5), 1, 1e-9)
    end
  end)

  it("front-loads out_cubic and back-loads in_cubic", function()
    expect.truthy(easing.out_cubic(0.25) > 0.25)
    expect.truthy(easing.in_cubic(0.25) < 0.25)
    expect.near(easing.in_out_cubic(0.5), 0.5, 1e-9)
  end)

  it("interpolates", function()
    expect.near(easing.lerp(10, 20, 0), 10)
    expect.near(easing.lerp(10, 20, 0.5), 15)
    expect.near(easing.lerp(10, 20, 1), 20)
  end)
end)
