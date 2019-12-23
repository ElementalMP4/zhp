// -------------------------------------------------------------------------- //
// Copyright (c) 2019, Jairus Martin.                                         //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //

// Some of this is ported from cpython's datetime module
const std = @import("std");
const time = std.time;
const math = std.math;

const Compare = std.mem.Compare;

const timezones = @import("timezones.zig");

const testing = std.testing;
const assert = std.debug.assert;

// Number of days in each month not accounting for leap year
pub const Weekday = enum {
    Monday = 1,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
    Sunday,
};

pub const Month = enum {
    January = 1,
    February,
    March,
    April,
    May,
    June,
    July,
    August,
    September,
    October,
    November,
    December
};


// Conversions to millis
pub const ms_per_day = time.s_per_day * time.ms_per_s;
pub const ms_per_hour = time.s_per_hour * time.ms_per_s;
pub const ms_per_min = time.s_per_min * time.ms_per_s;
pub const ms_per_s = time.ms_per_s;

pub const MIN_YEAR: u16 = 1;
pub const MAX_YEAR: u16 = 9999;
pub const MAX_ORDINAL: u32 = 3652059;

const DAYS_IN_MONTH = [12]u8{
    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
const DAYS_BEFORE_MONTH = [12]u16{
    0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334};

pub fn isLeapYear(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

pub fn isLeapDay(year: u32, month: u32, day: u32) bool {
    return isLeapYear(year) and month == 2 and day == 29;
}

test "leapyear" {
    testing.expect(isLeapYear(2019) == false);
    testing.expect(isLeapYear(2018) == false);
    testing.expect(isLeapYear(2017) == false);
    testing.expect(isLeapYear(2016) == true);
    testing.expect(isLeapYear(2000) == true);
    testing.expect(isLeapYear(1900) == false);
}

// Number of days before Jan 1st of year
pub fn daysBeforeYear(year: u32) u32 {
    var y: u32 = year - 1;
    return y*365 + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
}

// Days before 1 Jan 1970
const EPOCH = daysBeforeYear(1970) + 1;


test "daysBeforeYear" {
    testing.expect(daysBeforeYear(1996) == 728658);
    testing.expect(daysBeforeYear(2019) == 737059);
}

// Number of days in that month for the year
pub fn daysInMonth(year: u32, month: u32) u8 {
    assert(1 <= month and month <= 12);
    if (month == 2 and isLeapYear(year)) return 29;
    return DAYS_IN_MONTH[month-1];
}


test "daysInMonth" {
    testing.expect(daysInMonth(2019, 1) == 31);
    testing.expect(daysInMonth(2019, 2) == 28);
    testing.expect(daysInMonth(2016, 2) == 29);
}


// Number of days in year preceding the first day of month
pub fn daysBeforeMonth(year: u32, month: u32) u32 {
    assert(month >= 1 and month <= 12);
    var d = DAYS_BEFORE_MONTH[month-1];
    if (month > 2 and isLeapYear(year)) d += 1;
    return d;
}


// Return number of days since 01-Jan-0001
fn ymd2ord(year: u16, month: u8, day: u8) u32 {
    assert(month >= 1 and month <= 12);
    assert(day >= 1 and day <= daysInMonth(year, month));
    return daysBeforeYear(year) + daysBeforeMonth(year, month) + day;
}

test "ymd2ord" {
    testing.expect(ymd2ord(1970, 1, 1) == 719163);
    testing.expect(ymd2ord(28, 2, 29) == 9921);
    testing.expect(ymd2ord(2019, 11, 27) == 737390);
    testing.expect(ymd2ord(2019, 11, 28) == 737391);
}


test "days-before-year" {
    const DI400Y = daysBeforeYear(401); // Num of days in 400 years
    const DI100Y = daysBeforeYear(101); // Num of days in 100 years
    const DI4Y =   daysBeforeYear(5);   // Num of days in 4   years

    // A 4-year cycle has an extra leap day over what we'd get from pasting
    // together 4 single years.
    std.testing.expect(DI4Y == 4*365 + 1);

    // Similarly, a 400-year cycle has an extra leap day over what we'd get from
    // pasting together 4 100-year cycles.
    std.testing.expect(DI400Y == 4*DI100Y + 1);

    // OTOH, a 100-year cycle has one fewer leap day than we'd get from
    // pasting together 25 4-year cycles.
    std.testing.expect(DI100Y == 25*DI4Y - 1);
}


pub const Date = struct {
    year: u16,
    month: u4 = 1, // Month of year
    day: u8 = 1, // Day of month

    validated: u1 = @compileError("A Date must be created using Date.create"),

    // Create and validate the date
    pub fn create(year: u32, month: u32, day: u32) ! Date {
        if (year < MIN_YEAR or year > MAX_YEAR) return error.InvalidDate;
        if (month < 1 or month > 12) return error.InvalidDate;
        if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDate;
        // Since we just validated the ranges we can now savely cast
        return Date{
            .year = @intCast(u16, year),
            .month = @intCast(u4, month),
            .day = @intCast(u8, day),
            .validated = 1,
        };
    }

    // Return a copy of the date
    pub fn copy(self: Date) !Date {
        return Date.create(self.year, self.month, self.day);
    }

    // Create a Date from the number of days since 01-Jan-0001
    pub fn fromOrdinal(ordinal: u32) Date {
        // n is a 1-based index, starting at 1-Jan-1.  The pattern of leap years
        // repeats exactly every 400 years.  The basic strategy is to find the
        // closest 400-year boundary at or before n, then work with the offset
        // from that boundary to n.  Life is much clearer if we subtract 1 from
        // n first -- then the values of n at 400-year boundaries are exactly
        // those divisible by DI400Y:
        //
        //     D  M   Y            n              n-1
        //     -- --- ----        ----------     ----------------
        //     31 Dec -400        -DI400Y        -DI400Y -1
        //      1 Jan -399        -DI400Y +1     -DI400Y       400-year boundary
        //     ...
        //     30 Dec  000        -1             -2
        //     31 Dec  000         0             -1
        //      1 Jan  001         1              0            400-year boundary
        //      2 Jan  001         2              1
        //      3 Jan  001         3              2
        //     ...
        //     31 Dec  400         DI400Y        DI400Y -1
        //      1 Jan  401         DI400Y +1     DI400Y        400-year boundary
        assert(ordinal >= 1 and ordinal <= MAX_ORDINAL);

        var n = ordinal-1;
        comptime const DI400Y = daysBeforeYear(401); // Num of days in 400 years
        comptime const DI100Y = daysBeforeYear(101); // Num of days in 100 years
        comptime const DI4Y =   daysBeforeYear(5);   // Num of days in 4   years
        const n400 = @divFloor(n, DI400Y);
        n = @mod(n, DI400Y);
        var year = n400 * 400 + 1; //  ..., -399, 1, 401, ...

        // Now n is the (non-negative) offset, in days, from January 1 of year, to
        // the desired date.  Now compute how many 100-year cycles precede n.
        // Note that it's possible for n100 to equal 4!  In that case 4 full
        // 100-year cycles precede the desired day, which implies the desired
        // day is December 31 at the end of a 400-year cycle.
        const n100 = @divFloor(n, DI100Y);
        n = @mod(n, DI100Y);

        // Now compute how many 4-year cycles precede it.
        const n4 = @divFloor(n, DI4Y);
        n = @mod(n, DI4Y);

        // And now how many single years.  Again n1 can be 4, and again meaning
        // that the desired day is December 31 at the end of the 4-year cycle.
        const n1 = @divFloor(n, 365);
        n = @mod(n, 365);

        year += n100 * 100 + n4 * 4 + n1;

        if (n1 == 4 or n100 == 4) {
            assert(n == 0);
            return Date.create(year-1, 12, 31) catch unreachable;
        }

        // Now the year is correct, and n is the offset from January 1.  We find
        // the month via an estimate that's either exact or one too large.
        var leapyear = (n1 == 3) and (n4 != 24 or n100 == 3);
        assert(leapyear == isLeapYear(year));
        var month = (n + 50) >> 5;
        if (month == 0) month = 12; // Loop around
        var preceding = daysBeforeMonth(year, month);

        if (preceding > n) { // estimate is too large
            month -= 1;
            if (month == 0) month = 12; // Loop around
            preceding -= daysInMonth(year, month);
        }
        n -= preceding;
        // assert(n > 0 and n < daysInMonth(year, month));

        // Now the year and month are correct, and n is the offset from the
        // start of that month:  we're done!
        return Date.create(year, month, n+1) catch unreachable;
    }

    // Return proleptic Gregorian ordinal for the year, month and day.
    // January 1 of year 1 is day 1.  Only the year, month and day values
    // contribute to the result.
    pub fn toOrdinal(self: Date) u32 {
        return ymd2ord(self.year, self.month, self.day);
    }

    // Returns todays date
    pub fn now() Date {
        return Datetime.now().date;
    }

    // Create a date from the number of seconds since 1 Jan 0001
    pub fn fromSeconds(seconds: f64) Date {
        return Datetime.fromSeconds(seconds).date;
    }

    // Return the number of seconds since 1 Jan 0001
    pub fn toSeconds(self: Date) f64 {
        const s: u64 = @intCast(u64, self.toOrdinal()-1) * time.s_per_day;
        return @intToFloat(f64, s);
    }

    // Create a date from a UTC timestamp in milliseconds
    pub fn fromTimestamp(timestamp: u64) Date {
        const days = @divFloor(timestamp, ms_per_day) + EPOCH;
        assert(days <= MAX_ORDINAL);
        return Date.fromOrdinal(@intCast(u32, days));
    }

    // Create a UTC timestamp
    pub fn toTimestamp(self: Date) u64 {
        if (self.year < 1970) return 0;
        const days = daysBeforeYear(self.year) - EPOCH + self.dayOfYear();
        return @intCast(u64, days) * ms_per_day;
    }

    // ------------------------------------------------------------------------
    // Comparisons
    pub fn eql(self: Date, other: Date) bool {
        return self.cmp(other) == Compare.Equal;
    }

    pub fn cmp(self: Date, other: Date) Compare {
        if (self.year > other.year) return .GreaterThan;
        if (self.year < other.year) return .LessThan;
        if (self.month > other.month) return .GreaterThan;
        if (self.month < other.month) return .LessThan;
        if (self.day > other.day) return .GreaterThan;
        if (self.day < other.day) return .LessThan;
        return .Equal;
    }

    pub fn gt(self: Date, other: Date) bool {
        return self.cmp(other) == Compare.GreaterThan;
    }
    pub fn gte(self: Date, other: Date) bool {
        const r = self.cmp(other);
        return r == Compare.Equal or r == Compare.GreaterThan;
    }
    pub fn lt(self: Date, other: Date) bool {
        return self.cmp(other) == Compare.LessThan;
    }

    pub fn lte(self: Date, other: Date) bool {
        const r = self.cmp(other);
        return r == Compare.Equal or r == Compare.LessThan;
    }

    // ------------------------------------------------------------------------
    // Parsing
    // ------------------------------------------------------------------------

    // TODO: Parsing

    // ------------------------------------------------------------------------
    // Formatting
    // ------------------------------------------------------------------------

    // Return date in ISO format YYYY-MM-DD
    pub fn formatIso(self: Date, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{}-{}-{}",
            .{self.year, self.month, self.day});
    }

    // ------------------------------------------------------------------------
    // Properties
    // ------------------------------------------------------------------------

    // Return day of year starting with 1
    pub fn dayOfYear(self: Date) u16 {
        var d = self.toOrdinal() - daysBeforeYear(self.year);
        assert(d >=1 and d <= 366);
        return @intCast(u16, d);
    }

    // Return day of week starting with Monday = 1 and Sunday = 7
    pub fn dayOfWeek(self: Date) Weekday {
        const dow = @intCast(u3, self.toOrdinal() % 7);
        return @intToEnum(Weekday, if (dow == 0) 7 else dow);
    }

    // Return day of week starting with Monday = 0 and Sunday = 6
    pub fn weekday(self: Date) u4 {
        return @enumToInt(self.dayOfWeek()) - 1;
    }

    // Return whether the date is a weekend (Saturday or Sunday)
    pub fn isWeekend(self: Date) bool {
        return self.weekday() >= 5;
    }

    // Return the name of the day of the week, eg "Sunday"
    pub fn weekdayName(self: Date) []const u8 {
        return @tagName(self.dayOfWeek());
    }

    // Return the name of the day of the month, eg "January"
    pub fn monthName(self: Date) []const u8 {
        assert(self.month >= 1 and self.month <= 12);
        return @tagName(@intToEnum(Month, self.month));
    }

    // ------------------------------------------------------------------------
    // Operations
    // ------------------------------------------------------------------------

    // Return a copy of the date shifted by the given number of days
    pub fn shiftDays(self: Date, days: i32) Date {
        return self.shift(Delta{.days=days});
    }

    // Return a copy of the date shifted by the given number of years
    pub fn shiftYears(self: Date, years: i16) Date {
        return self.shift(Delta{.years=years});
    }

    pub const Delta = struct {
        years: i16 = 0,
        days: i32 = 0,
    };

    // Return a copy of the date shifted in time by the delta
    pub fn shift(self: Date, delta: Delta) Date {
        if (delta.years == 0 and delta.days == 0) {
            return self.copy() catch unreachable;
        }

        // Shift year
        var year = self.year;
        if (delta.years < 0) {
            year -= @intCast(u16, -delta.years);
        } else {
            year += @intCast(u16, delta.years);
        }
        var ord = daysBeforeYear(year);
        var days = self.dayOfYear();
        const fromLeap = isLeapYear(self.year);
        const toLeap = isLeapYear(year);
        if (days == 59 and fromLeap and toLeap) {
            // No change before leap day
        } else if (days < 59) {
            // No change when jumping from leap day to leap day
        } else if (toLeap and !fromLeap) {
            // When jumping to a leap year to non-leap year
            // we have to add a leap day to the day of year
            days += 1;
        } else if (fromLeap and !toLeap) {
            // When jumping from leap year to non-leap year we have to undo
            // the leap day added to the day of yearear
            days -= 1;
        }
        ord += days;

        // Shift days
        if (delta.days < 0) {
            ord -= @intCast(u32, -delta.days);
        } else {
            ord += @intCast(u32, delta.days);
        }
        return Date.fromOrdinal(ord);
    }

};


test "date-now" {
    var date = Date.now();
}

test "date-compare" {
    var d1 = try Date.create(2019, 7, 3);
    var d2 = try Date.create(2019, 7, 3);
    var d3 = try Date.create(2019, 6, 3);
    var d4 = try Date.create(2020, 7, 3);
    testing.expect(d1.eql(d2));
    testing.expect(d1.gt(d3));
    testing.expect(d3.lt(d2));
    testing.expect(d4.gt(d2));
}

test "date-from-ordinal" {
    var date = Date.fromOrdinal(9921);
    testing.expectEqual(date.year, 28);
    testing.expectEqual(date.month, 2);
    testing.expectEqual(date.day, 29);
    testing.expectEqual(date.toOrdinal(), 9921);

    date = Date.fromOrdinal(737390);
    testing.expectEqual(date.year, 2019);
    testing.expectEqual(date.month, 11);
    testing.expectEqual(date.day, 27);
    testing.expectEqual(date.toOrdinal(), 737390);

    date = Date.fromOrdinal(719163);
    testing.expectEqual(date.year, 1970);
    testing.expectEqual(date.month, 1);
    testing.expectEqual(date.day, 1);
    testing.expectEqual(date.toOrdinal(), 719163);
}

test "date-from-seconds" {
    // Min check
    var min_date = try Date.create(1, 1, 1);
    var date = Date.fromSeconds(0);
    testing.expect(date.eql(min_date));
    testing.expectEqual(date.toSeconds(), 0);


    const t = 63710928000.000;
    date = Date.fromSeconds(t);
    testing.expectEqual(date.year, 2019);
    testing.expectEqual(date.month, 12);
    testing.expectEqual(date.day, 3);
    testing.expectEqual(date.toSeconds(), t);

    // Max check
    var max_date = try Date.create(9999, 12, 31);
    const tmax: f64 = @intToFloat(f64, MAX_ORDINAL-1) * time.s_per_day;
    date = Date.fromSeconds(tmax);
    testing.expect(date.eql(max_date));
    testing.expectEqual(date.toSeconds(), tmax);
}


test "date-day-of-year" {
    var date = try Date.create(1970, 1, 1);
    testing.expect(date.dayOfYear() == 1);
}

test "date-day-of-week" {
    var date = try Date.create(2019, 11, 27);
    testing.expectEqual(date.weekday(), 2);
    testing.expectEqual(date.dayOfWeek(), .Wednesday);
    testing.expectEqualSlices(u8, date.monthName(), "November");
    testing.expectEqualSlices(u8, date.weekdayName(), "Wednesday");
    testing.expect(!date.isWeekend());

    date = try Date.create(1776, 6, 4);
    testing.expectEqual(date.weekday(), 1);
    testing.expectEqual(date.dayOfWeek(), .Tuesday);
    testing.expectEqualSlices(u8, date.monthName(), "June");
    testing.expectEqualSlices(u8, date.weekdayName(), "Tuesday");
    testing.expect(!date.isWeekend());

    date = try Date.create(2019, 12, 1);
    testing.expectEqualSlices(u8, date.monthName(), "December");
    testing.expectEqualSlices(u8, date.weekdayName(), "Sunday");
    testing.expect(date.isWeekend());
}

test "date-shift-days" {
    var date = try Date.create(2019, 11, 27);
    var d = date.shiftDays(-2);
    testing.expectEqual(d.day, 25);
    testing.expectEqualSlices(u8, d.weekdayName(), "Monday");

    // Ahead one week
    d = date.shiftDays(7);
    testing.expectEqualSlices(u8, d.weekdayName(), date.weekdayName());
    testing.expectEqual(d.month, 12);
    testing.expectEqualSlices(u8, d.monthName(), "December");
    testing.expectEqual(d.day, 4);

    d = date.shiftDays(0);
    testing.expect(date.eql(d));

}

test "date-shift-years" {
    // Shift including a leap year
    var date = try Date.create(2019, 11, 27);
    var d = date.shiftYears(-4);
    testing.expect(d.eql(try Date.create(2015, 11, 27)));

    d = date.shiftYears(15);
    testing.expect(d.eql(try Date.create(2034, 11, 27)));

    // Shifting from leap day
    var leap_day = try Date.create(2020, 2, 29);
    d = leap_day.shiftYears(1);
    testing.expect(d.eql(try Date.create(2021, 2, 28)));

    // Before leap day
    date = try Date.create(2020, 2, 2);
    d = date.shiftYears(1);
    testing.expect(d.eql(try Date.create(2021, 2, 2)));

    // After leap day
    date = try Date.create(2020, 3, 1);
    d = date.shiftYears(1);
    testing.expect(d.eql(try Date.create(2021, 3, 1)));

    // From leap day to leap day
    d = leap_day.shiftYears(4);
    testing.expect(d.eql(try Date.create(2024, 2, 29)));

}


test "date-create" {
    testing.expectError(
        error.InvalidDate, Date.create(2019, 2, 29));

    var date = Date.fromTimestamp(1574908586928);
    testing.expect(date.eql(try Date.create(2019, 11, 28)));
}

test "date-copy" {
    var d1 = try Date.create(2020, 1, 1);
    var d2 = try d1.copy();
    testing.expect(d1.eql(d2));
}


pub const Timezone = struct {
    offset: i16, // In minutes
    name: []const u8,

    // Auto register timezones
    pub fn create(name: []const u8, offset: i16) Timezone {
        const self = Timezone{.offset=offset, .name=name};
        return self;
    }
};


pub const Time = struct {
    hour: u8 = 0, // 0 to 23
    minute: u8 = 0, // 0 to 59
    second: u8 = 0, // 0 to 59
    microsecond: u32 = 0, // 0 to 999999 TODO: Should this be u20?
    zone: *const Timezone = &timezones.UTC,

    validated: u1 = @compileError("A Time must be created using Time.create"),

    // ------------------------------------------------------------------------
    // Constructors
    // ------------------------------------------------------------------------
    pub fn now() Time {
        return Datetime.now().time;
    }

    // Create a Time struct and validate that all fields are in range
    pub fn create(hour: u32, minute: u32, second: u32, microsecond: u32,
                  zone: ?*const Timezone) !Time {
        if (hour > 23 or minute > 59 or second > 59 or microsecond > 999999) {
            return error.InvalidTime;
        }
        return Time{
            .hour = @intCast(u8, hour),
            .minute = @intCast(u8, minute),
            .second = @intCast(u8, second),
            .microsecond = microsecond,
            .zone = zone orelse &timezones.UTC,
            .validated = 1,
        };
    }

    // Create a copy of the Time
    pub fn copy(self: Time) !Time {
        return Time.create(self.hour, self.minute, self.second,
                           self.microsecond, self.zone);
    }

    // Create Time from a UTC Timestamp
    pub fn fromTimestamp(timestamp: u64) Time {
        var t = @intCast(u32, if (timestamp > ms_per_day)
            @mod(timestamp, ms_per_day) else timestamp);
        // t is now only the milliseconds part of the day
        const h = @divFloor(t, ms_per_hour);
        t -= h * ms_per_hour;
        const m = @divFloor(t, ms_per_min);
        t -= m * ms_per_min;
        const s = @divFloor(t, ms_per_s);
        const us = (t - s*ms_per_s) * 1000; // Convert to us
        return Time.create(h, m, s, us, &timezones.UTC) catch unreachable;
    }

    // Convert to a time in seconds relative to the UTC timezones
    // excluding the microsecond component
    pub fn totalSeconds(self: Time) i32 {
        return @intCast(i32, self.hour) * time.s_per_hour +
            (@intCast(i32, self.minute) - self.zone.offset) * time.s_per_min +
            @intCast(i32, self.second);
    }

    // Convert to a time in seconds relative to the UTC timezones
    // including the microsecond component
    pub fn toSeconds(self: Time) f64 {
        const s: f64 = @intToFloat(f64, self.totalSeconds());
        const us: f64 = @intToFloat(f32, self.microsecond) / time.us_per_s;
        return s + us;
    }

    // Convert to a timestamp in milliseconds from UTC
    // excluding the microsecond fraction
    pub fn toTimestamp(self: Time) i32 {
        return @intCast(i32, self.hour) * ms_per_hour +
               (@intCast(i32, self.minute)-self.zone.offset) * ms_per_min +
               @intCast(i32, self.second) * ms_per_s +
               @intCast(i32, @divFloor(self.microsecond, 1000));
    }

    // -----------------------------------------------------------------------
    // Comparisons
    // -----------------------------------------------------------------------
    pub fn eql(self: Time, other: Time) bool {
        return self.cmp(other) == Compare.Equal;
    }

    pub fn cmp(self: Time, other: Time) Compare {
        var t1 = self.totalSeconds();
        var t2 = other.totalSeconds();
        if (t1 > t2) return .GreaterThan;
        if (t1 < t2) return .LessThan;
        if (self.microsecond > other.microsecond) return .GreaterThan;
        if (self.microsecond < other.microsecond) return .LessThan;
        return .Equal;
    }

    pub fn gt(self: Time, other: Time) bool {
        return self.cmp(other) == Compare.GreaterThan;
    }

    pub fn gte(self: Time, other: Time) bool {
        const r = self.cmp(other);
        return r == Compare.Equal or r == Compare.GreaterThan;
    }

    pub fn lt(self: Time, other: Time) bool {
        return self.cmp(other) == Compare.LessThan;
    }

    pub fn lte(self: Time, other: Time) bool {
        const r = self.cmp(other);
        return r == Compare.Equal or r == Compare.LessThan;
    }

    // -----------------------------------------------------------------------
    // Methods
    // -----------------------------------------------------------------------
    pub fn amOrPm(self: Time) []const u8 {
        return if (self.hour > 12) return "PM" else "AM";
    }
};

test "time-create" {
    var t = Time.fromTimestamp(1574908586928);
    testing.expect(t.hour == 2);
    testing.expect(t.minute == 36);
    testing.expect(t.second == 26);
    testing.expect(t.microsecond == 928000);
    t = Time.now();
}

test "time-copy" {
    var t1 = try Time.create(8, 30, 0, 0, null);
    var t2 = try t1.copy();
    testing.expect(t1.eql(t2));
}

test "time-compare" {
    var t1 = try Time.create(8, 30, 0, 0, null);
    var t2 = try Time.create(9, 30, 0, 0, null);
    var t3 = try Time.create(8, 00, 0, 0, null);
    var t4 = try Time.create(9, 30, 17, 0, null);

    testing.expect(t1.lt(t2));
    testing.expect(t1.gt(t3));
    testing.expect(t2.lt(t4));
    testing.expect(t2.lt(t4));

    var t5 = try Time.create(3, 30, 0, 0, &timezones.America.New_York);
    testing.expect(t1.eql(t5));

    var t6 = try Time.create(9, 30, 0, 0, &timezones.Europe.Zurich);
    testing.expect(t1.eql(t5));
}


pub const Datetime = struct {
    date: Date,
    time: Time,

    // An absolute or relative delta
    // if years is defined a date is date
    // TODO: Validate years before allowing it to be created
    pub const Delta = struct {
        years: i16 = 0,
        days: i32 = 0,
        seconds: i64 = 0,
        microseconds: i32 = 0,
        relative_to: ?Datetime = null,

        pub fn sub(self: *Delta, other: *Delta) Delta {
            return Delta{
                .years = self.years - other.years,
                .days = self.days - other.days,
                .seconds = self.seconds - other.seconds,
                .microseconds = self.microseconds - other.microseconds,
                .relative_to = self.relative_to,
            };
        }

        pub fn add(self: *Delta, other: *Delta) Delta {
            return Delta{
                .years = self.years + other.years,
                .days = self.days + other.days,
                .seconds = self.seconds + other.seconds,
                .microseconds = self.microseconds + other.microseconds,
                .relative_to = self.relative_to,
            };
        }

        // Total seconds in the duration ignoring the microseconds fraction
        pub fn totalSeconds(self: *Delta) i64 {
            // Calculate the total number of days we're shifting
            var days = self.days;
            if (self.relative_to) |dt| {
                if (self.years != 0) {
                    const a = daysBeforeYear(dt.date.year);
                    // Must always subtract greater of the two
                    if (self.years > 0) {
                        const y = @intCast(u32, self.years);
                        const b = daysBeforeYear(dt.date.year + y);
                        days += @intCast(i32, b - a);
                    } else {
                        const y = @intCast(u32, -self.years);
                        assert(y < dt.date.year); // Does not work below year 1
                        const b = daysBeforeYear(dt.date.year - y);
                        days -= @intCast(i32, a - b);
                    }
                }
            } else {
                // Cannot use years without a relative to date
                // otherwise any leap days will screw up results
                assert(self.years == 0);
            }
            var s = self.seconds;
            var us = self.microseconds;
            if (us > time.us_per_s) {
                const ds = @divFloor(us, time.us_per_s);
                us -= ds * time.us_per_s;
                s += ds;
            } else if (us < -time.us_per_s) {
                const ds = @divFloor(us, -time.us_per_s);
                us += ds * time.us_per_s;
                s -= ds;
            }
            return (days * time.s_per_day + s);
        }
    };

    // ------------------------------------------------------------------------
    // Constructors
    // ------------------------------------------------------------------------
    pub fn now() Datetime {
        return Datetime.fromTimestamp(std.time.milliTimestamp());
    }

    pub fn create(year: u32, month: u32, day: u32, hour: u32, minute: u32,
            second: u32, microsecond: u32, zone: ?*const Timezone) !Datetime {
        return Datetime{
            .date = try Date.create(year, month, day),
            .time = try Time.create(hour, minute, second, microsecond, zone),
        };
    }

    // Return a copy
    pub fn copy(self: Datetime) !Datetime {
        return Datetime{
            .date = try self.date.copy(),
            .time = try self.time.copy()
        };
    }

    pub fn fromDate(year: u16, month: u8, day: u8) !Datetime {
        return Datetime{
            .date = try Date.create(year, month, day),
            .time = try Time.create(0, 0, 0, 0, &timezones.UTC),
        };
    }

    // From seconds since 1 Jan 0001
    pub fn fromSeconds(seconds: f64) Datetime {
        assert(seconds >= 0);

        // Convert to s and us
        var r = math.modf(seconds);
        var timestamp = @floatToInt(u64, r.ipart); // Seconds
        var us = @floatToInt(u32, math.round(r.fpart * 1e6)); // Us
        if (us >= time.us_per_s) {
            timestamp -= 1;
            us -= time.us_per_s;
        } else if (us < 0) {
            timestamp -= 1;
            us += time.us_per_s;
        }

        const days = @divFloor(timestamp, time.s_per_day);
        assert(days < MAX_ORDINAL);
        // Add min ordinal of 1
        var date = Date.fromOrdinal(@intCast(u32, days + 1));

        // t is now seconds lef
        timestamp -= days * time.s_per_day;
        var t = @intCast(u32, timestamp);
        const h = @divFloor(t, time.s_per_hour);
        t -= h * time.s_per_hour;
        const m = @divFloor(t, time.s_per_min);
        t -= m * time.s_per_min;
        const s = t;
        return Datetime{
            .date = date,
            .time = Time.create(h, m, s, us, &timezones.UTC)
                catch unreachable, // If this fails it's a bug
        };
    }

    // Seconds since 1 Jan 0001 including mircoseconds
    pub fn toSeconds(self: Datetime) f64 {
        return self.date.toSeconds() + self.time.toSeconds();
    }

    // From POSIX timestamp in milliseoncds since 1 Jan 1970
    pub fn fromTimestamp(timestamp: u64) Datetime {
        const d = @divFloor(timestamp, ms_per_day);
        const days = d + EPOCH;
        assert(days <= MAX_ORDINAL);
        var date = Date.fromOrdinal(@intCast(u32, days));
        var t = Time.fromTimestamp(timestamp - d * ms_per_day);
        return Datetime{.date = date, .time = t};
    }

    // To a UTC POSIX timestamp
    pub fn toTimestamp(self: Datetime) u64 {
        const ts = self.time.toTimestamp();
        const ds = self.date.toTimestamp();
        if (ts >= 0) {
            return ds + @intCast(u64, ts);
        }
        const t = @intCast(u64, -ts);
        if (ds > t) {
            return ds - t;
        }
        return 0; // Less than 1 Jan 1970
    }

    // -----------------------------------------------------------------------
    // Comparisons
    // -----------------------------------------------------------------------
    pub fn eql(self: Datetime, other: Datetime) bool {
        return self.cmp(other) == Compare.Equal;
    }

    pub fn cmp(self: Datetime, other: Datetime) Compare {
        var r = self.date.cmp(other.date);
        if (r != .Equal) return r;
        r = self.time.cmp(other.time);
        if (r != .Equal) return r;
        return .Equal;
    }

    pub fn gt(self: Datetime, other: Datetime) bool {
        return self.cmp(other) == Compare.GreaterThan;
    }

    pub fn gte(self: Datetime, other: Datetime) bool {
        const r = self.cmp(other);
        return r == Compare.Equal or r == Compare.GreaterThan;
    }

    pub fn lt(self: Datetime, other: Datetime) bool {
        return self.cmp(other) == Compare.LessThan;
    }

    pub fn lte(self: Datetime, other: Datetime) bool {
        const r = self.cmp(other);
        return r == Compare.Equal or r == Compare.LessThan;
    }

    // -----------------------------------------------------------------------
    // Methods
    // -----------------------------------------------------------------------

    // Return a Datetime.Delta relative to this date
    pub fn sub(self: Datetime, other: Datetime) Delta {
        var days = @intCast(i32, self.date.toOrdinal())
                   - @intCast(i32, other.date.toOrdinal());
        var seconds = self.time.totalSeconds() - other.time.totalSeconds();
        if (self.time.zone.offset != other.time.zone.offset) {
            const mins = (self.time.zone.offset - other.time.zone.offset);
            seconds += mins * time.s_per_min;
        }
        const us = @intCast(i32, self.time.microsecond)
                    - @intCast(i32, other.time.microsecond);
        return Delta{.days=days, .seconds=seconds, .microseconds=us};
    }

    // Create a Datetime shifted by the given number of years
    pub fn shiftYears(self: Datetime, years: i16) Datetime {
        return self.shift(Delta{.years=years});
    }

    // Create a Datetime shifted by the given number of days
    pub fn shiftDays(self: Datetime, days: i32) Datetime {
        return self.shift(Delta{.days=days});
    }

    // Create a Datetime shifted by the given number of hours
    pub fn shiftHours(self: Datetime, hours: i32) Datetime {
        return self.shift(Delta{.seconds=hours*time.s_per_hour});
    }

    // Create a Datetime shifted by the given number of minutes
    pub fn shiftMinutes(self: Datetime, minutes: i32) Datetime {
        return self.shift(Delta{.seconds=minutes*time.s_per_min});
    }

    // Convert to the given timeszone
    pub fn shiftTimezone(self: Datetime, zone: *const Timezone) Datetime {
        var dt =
            if (self.time.zone.offset == zone.offset)
                (self.copy() catch unreachable)
            else
                self.shiftMinutes(zone.offset-self.time.zone.offset);
        dt.time.zone = zone;
        return dt;
    }

    // Create a Datetime shifted by the given number of seconds
    pub fn shiftSeconds(self: Datetime, seconds: i64) Datetime {
        return self.shift(Delta{.seconds=seconds});
    }

    // Create a Datetime shifted by the given Delta
    pub fn shift(self: Datetime, delta: Delta) Datetime {
        var days = delta.days;
        var s = delta.seconds + self.time.totalSeconds();

        // Rollover us to s
        var us = delta.microseconds + @intCast(i32, self.time.microsecond);
        if (us > time.us_per_s) {
            s += 1;
            us -= time.us_per_s;
        } else if (us < -time.us_per_s) {
            s -= 1;
            us += time.us_per_s;
        }
        assert(us >= 0 and us < time.us_per_s);
        const microsecond = @intCast(u32, us);

        // Rollover s to days
        if (s > time.s_per_day) {
            const d = @divFloor(s, time.s_per_day);
            days += @intCast(i32, d);
            s -= d * time.s_per_day;
        } else if (s < 0) {
            if (s < -time.s_per_day) { // Wrap multiple
                const d = @divFloor(s, -time.s_per_day);
                days -= @intCast(i32, d);
                s += d * time.s_per_day;
            }
            days -= 1;
            s = time.s_per_day + s;
        }
        assert(s >= 0 and s < time.s_per_day);

        var seconds = @intCast(u32, s);
        const hour = @divFloor(seconds, time.s_per_hour);
        seconds -= hour * time.s_per_hour;
        const minute = @divFloor(seconds, time.s_per_min);
        seconds -= minute * time.s_per_min;

        return Datetime{
            .date=self.date.shift(Date.Delta{.years=delta.years, .days=days}),
            .time=Time.create(hour, minute, seconds, microsecond, self.time.zone)
                catch unreachable // This is a bug
        };
    }

    // ------------------------------------------------------------------------
    // Formatting methods
    // ------------------------------------------------------------------------

    // Formats a timestamp in the format used by HTTP.
    // eg "Tue, 15 Nov 1994 08:12:31 GMT"
    pub fn formatHttp(self: *Datetime, allocator: *std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{}, {} {} {} {d:0>2}:{d:0>2}:{d:0>2} {}", .{
            self.date.weekdayName()[0..3],
            self.date.day,
            self.date.monthName()[0..3],
            self.date.year,
            self.time.hour,
            self.time.minute,
            self.time.second,
            self.time.zone.name // TODO: Should be GMT
        });
    }

    // Formats a timestamp in the format used by HTTP.
    // eg "Tue, 15 Nov 1994 08:12:31 GMT"
    pub fn formatHttpFromTimestamp(allocator: *std.mem.Allocator, timestamp: u64) ![]const u8 {
        return Datetime.fromTimestamp(timestamp).formatHttp(allocator);
    }

    // From time in nanoseconds
    pub fn formatHttpFromModifiedDate(allocator: *std.mem.Allocator, mtime: i64) ![]const u8 {
        comptime const ns_per_ms = time.ns_per_s/time.ms_per_s;
        const ts = @divFloor(mtime, ns_per_ms);
        if (ts < 0) {
            var dt = Datetime.fromTimestamp(0);
            return dt.shiftSeconds(ts).formatHttp(allocator);
        } else {
            return Datetime.formatHttpFromTimestamp(allocator, @intCast(u64, ts));
        }
    }

};


test "datetime-now" {
    var t = Datetime.now();
}

test "datetime-create-timestamp" {
    //var t = Datetime.now();
    const ts = 1574908586928;
    var t = Datetime.fromTimestamp(ts);
    testing.expect(t.date.eql(try Date.create(2019, 11, 28)));
    testing.expect(t.time.eql(try Time.create(2, 36, 26, 928000, null)));
    testing.expectEqualSlices(u8, t.time.zone.name, "UTC");
    testing.expectEqual(t.toTimestamp(), ts);
}

test "datetime-from-seconds" {
    const ts: f64 = 63710916533.835075;
    var t = Datetime.fromSeconds(ts);
    testing.expect(t.date.year == 2019);
    testing.expect(t.date.eql(try Date.create(2019, 12, 2)));
    testing.expect(t.time.eql(try Time.create(20, 48, 53, 835075, null)));
    testing.expectEqual(t.toSeconds(), ts);

}


test "datetime-shift-timezones" {
    const ts = 1574908586928;
    var t = Datetime.fromTimestamp(ts).shiftTimezone(
        &timezones.America.New_York);

    testing.expect(t.date.eql(try Date.create(2019, 11, 27)));
    testing.expectEqual(t.time.hour, 21);
    testing.expectEqual(t.time.minute, 36);
    testing.expectEqual(t.time.second, 26);
    testing.expectEqual(t.time.microsecond, 928000);
    testing.expectEqualSlices(u8, t.time.zone.name, "America/New_York");
    testing.expectEqual(t.toTimestamp(), ts);

}

test "datetime-shift" {
    var dt = try Datetime.create(2019, 12, 2, 11, 51, 13, 466545, null);

    testing.expect(dt.shiftYears(0).eql(dt));
    testing.expect(dt.shiftDays(0).eql(dt));
    testing.expect(dt.shiftHours(0).eql(dt));

    var t = dt.shiftDays(7);
    testing.expect(t.date.eql(try Date.create(2019, 12, 9)));
    testing.expect(t.time.eql(dt.time));

    t = dt.shiftDays(-3);
    testing.expect(t.date.eql(try Date.create(2019, 11, 29)));
    testing.expect(t.time.eql(dt.time));

    t = dt.shiftHours(18);
    testing.expect(t.date.eql(try Date.create(2019, 12, 3)));
    testing.expect(t.time.eql(try Time.create(5, 51, 13, 466545, null)));

    t = dt.shiftHours(-36);
    testing.expect(t.date.eql(try Date.create(2019, 11, 30)));
    testing.expect(t.time.eql(try Time.create(23, 51, 13, 466545, null)));

    t = dt.shiftYears(1);
    testing.expect(t.date.eql(try Date.create(2020, 12, 2)));
    testing.expect(t.time.eql(dt.time));

    t = dt.shiftYears(-3);
    testing.expect(t.date.eql(try Date.create(2016, 12, 2)));
    testing.expect(t.time.eql(dt.time));

}

test "datetime-compare" {
    var dt1 = try Datetime.create(2019, 12, 2, 11, 51, 13, 466545, null);
    var dt2 = try Datetime.fromDate(2016, 12, 2);
    testing.expect(dt2.lt(dt1));

    var dt3 = Datetime.now();
    testing.expect(dt3.gt(dt2));

    var dt4 = try dt3.copy();
    testing.expect(dt3.eql(dt4));

    var dt5 = dt1.shiftTimezone(&timezones.America.Louisville);
    testing.expect(dt5.eql(dt1));
}

test "datetime-subtract" {
     var a = try Datetime.create(2019, 12, 2, 11, 51, 13, 466545, null);
     var b = try Datetime.create(2019, 12, 5, 11, 51, 13, 466545, null);
     var delta = a.sub(b);
     testing.expectEqual(delta.days, -3);
     testing.expectEqual(delta.totalSeconds(), -3 * time.s_per_day);
     delta = b.sub(a);
     testing.expectEqual(delta.days, 3);
     testing.expectEqual(delta.totalSeconds(), 3 * time.s_per_day);

     b = try Datetime.create(2019, 12, 2, 11, 0, 0, 466545, null);
     delta = a.sub(b);
     testing.expectEqual(delta.totalSeconds(), 13 + 51* time.s_per_min);
}

test "readme-example" {
    const allocator = std.heap.page_allocator;
    var date = try Date.create(2019, 12, 25);
    var next_year = date.shiftDays(7);
    assert(next_year.year == 2020);
    assert(next_year.month == 1);
    assert(next_year.day == 1);

    // In UTC
    var now = Datetime.now();
    var now_str = try now.formatHttp(allocator);
    defer allocator.free(now_str);
    std.debug.warn("The time is now: {}\n", .{now_str});
    // The time is now: Fri, 20 Dec 2019 22:03:02 UTC


}