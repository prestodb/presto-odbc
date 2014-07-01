
import std.stdio : writeln;
import std.array : empty, front, popFront;
import std.conv : to, text, wtext;
import std.variant : Variant;
import std.typetuple : TypeTuple;
import std.traits : isSomeString, Unqual;

import sqlext;
import odbcinst;

import util : logMessage, copyToBuffer, dllEnforce, OutputWChar, wcharsToBytes;

/**
  An OdbcStatement handle object is allocated for each HSTATEMENT requested by the driver/client.
*/
final class OdbcStatement {
  this() {
    latestOdbcResult = new EmptyOdbcResult();
  }

  ColumnBinding[uint] columnBindings;
  OdbcResult latestOdbcResult;
  wstring query;
}

unittest {
  enum testSqlTypeId = SQL_C_TYPE_ID.SQL_C_LONG;
  alias testSqlType = int;
  auto binding = ColumnBinding(new SQLLEN);
  binding.columnType = testSqlTypeId;
  binding.outputBuffer.length = testSqlType.sizeof;
  binding.numberOfBytesWritten = -1;

  copyToOutput!(testSqlType)(Variant(5), binding);
  assert(binding.numberOfBytesWritten == testSqlType.sizeof);
  assert(*(cast(testSqlType*) binding.outputBuffer) == 5);
}

unittest {
  enum testSqlTypeId = SQL_C_TYPE_ID.SQL_C_CHAR;
  alias testSqlType = string;
  auto binding = ColumnBinding(new SQLLEN);
  binding.columnType = testSqlTypeId;
  binding.outputBuffer.length = 10;
  binding.numberOfBytesWritten = -1;

  copyToOutput!(testSqlType)(Variant("Hello world, my name is Fred"), binding);
  assert(binding.numberOfBytesWritten == 9);
  assert(cast(char[]) binding.outputBuffer == "Hello wor\0");
}

//Writes the value inside the Variant into the buffer specified by the binding
void copyToOutput(SQL_C_TYPE)(Variant value, ref ColumnBinding binding) {

  static void copyToOutputImpl(VARIANT_TYPE)(Variant value, ref ColumnBinding binding) {
    alias ResultType = firstNonVoidType!(SQL_C_TYPE, VARIANT_TYPE);

    with (binding) {
      static if (is(VARIANT_TYPE == typeof(null))) {
        numberOfBytesWritten = SQL_NULL_DATA;
      } else static if (is(ResultType == string)) {
        static if (is(VARIANT_TYPE == string)) {
          auto srcString = value.get!VARIANT_TYPE;
        } else {
          logMessage("Converting a non-string type to a string type for output");
          auto srcString = to!ResultType(value.get!VARIANT_TYPE);
        }
        numberOfBytesWritten = copyToBuffer(srcString, cast(char[]) outputBuffer);
      } else {
        assert(!isSomeString!VARIANT_TYPE, "" ~ text(typeid(ResultType)) ~ " " ~ text(typeid(VARIANT_TYPE)));

        auto resultPtr = cast(ResultType*) outputBuffer.ptr;
        *resultPtr = to!ResultType(value.get!VARIANT_TYPE);
        numberOfBytesWritten = ResultType.sizeof;
      }
    }
  } //with

  dispatchOnVariantType!(copyToOutputImpl)(value, binding);
}

unittest {
  dispatchOnSqlCType!(requireIntType)(SQL_C_TYPE_ID.SQL_C_LONG);
}

auto dispatchOnSqlCType(alias fun, TList...)(SQL_C_TYPE_ID type, auto ref TList vs) {
  auto impl(SqlTList...)() {
    static if (SqlTList.length <= 1) {
      assert(false, "Bad SQL_TYPE_ID passed: " ~ text(type));
    } else {
      if (type == SqlTList[0]) {
        return fun!(SqlTList[1])(vs);
      } else {
        return impl!(SqlTList[2 .. $])();
      }
    }
  }
  return impl!SQL_C_TYPES();
}

version(unittest) {
  static void requireIntType(T, TList...)(TList) {
    static if (!is(T == int)) {
      assert(false, "Wrong type dispatched");
    }
  }
}

unittest {
  int testValue = 5;
  dispatchOnVariantType!(requireIntType)(Variant(testValue));
}

auto dispatchOnVariantType(alias fun, TList...)(Variant value, auto ref TList vs) {
  auto type = value.type();
  foreach (T; TypeTuple!(string, short, ushort, int, uint, long, ulong, bool, SQL_TYPE_ID, typeof(null))) {
    if(type == typeid(T)) {
      return fun!T(value, vs);
    }
  }
  assert(false, "Unexpected type in variant: " ~ text(value.type()));
}

unittest {
  static assert(is(firstNonVoidType!(int, void, double) == int));
  static assert(is(firstNonVoidType!(void, double) == double));
  static assert(is(firstNonVoidType!(void, void, double) == double));
}

template firstNonVoidType(TList...) {
  static assert(TList.length != 0, "No non-void types in the list");

  static if (is(TList[0] == void)) {
    alias firstNonVoidType = .firstNonVoidType!(TList[1 .. $]);
  } else {
    alias firstNonVoidType = TList[0];
  }
}

/**
 * Stores information about how to return results to the user for a particular column.
 */
struct ColumnBinding {
  this(SQLLEN* indicator) {
    this.indicator = indicator;
  }

  SQL_C_TYPE_ID columnType;
  void[] outputBuffer;
  SQLLEN* indicator;

  @property {
    SQLLEN numberOfBytesWritten() {
      assert(indicator != null);
      return *indicator;
    }
    void numberOfBytesWritten(SQLLEN value) {
      if (indicator != null) {
        *indicator = value;
      }
    }
  }
}

/**
 * A range that allows retrieving one row at a time from the result set of a query.
 */
interface OdbcResult {
  @property {
    bool empty();
    OdbcResultRow front();
    void popFront();

    uint numberOfColumns();
  }
}

final class EmptyOdbcResult : OdbcResult {
  @property {
    bool empty() { return true; }
    OdbcResultRow front() { return null; }
    void popFront() {}

    uint numberOfColumns() { return 0; }
  }
}

interface OdbcResultRow {
  Variant dataAt(int column);
}

final class TableInfoResult : OdbcResult {
  @property {
    bool empty() {
      return poppedContents;
    }

    TableInfoResultRow front() {
      assert(!empty);
      return result;
    }

    void popFront() {
      poppedContents = true;
    }

    uint numberOfColumns() {
      return TableInfoResultColumns.max;
    }
  }

private:
  TableInfoResultRow result = new TableInfoResultRow();
  //Only returning 1 made-up table for now.
  bool poppedContents = false;
}

final class TableInfoResultRow : OdbcResultRow {
  Variant dataAt(int column) {
    with (TableInfoResultColumns) {
      switch (column) {
      case TABLE_CAT:
        return Variant("tpch");
      case TABLE_SCHEM:
        return Variant("tiny");
      case TABLE_NAME:
        return Variant("orders");
      case TABLE_TYPE:
        return Variant("TABLE");
      case REMARKS:
        return Variant("A faux table for testing");
      default:
        dllEnforce(false, "Non-existant column " ~ text(cast(TableInfoResultColumns) column));
        assert(false, "Silence compiler errors about not returning");
      }
    }
  }
}

enum TableInfoResultColumns {
  TABLE_CAT = 1,
  TABLE_SCHEM,
  TABLE_NAME,
  TABLE_TYPE,
  REMARKS
}


final class ColumnsResult : OdbcResult {
  @property {
    bool empty() {
      return count == result.length;
    }

    OdbcResultRow front() {
      assert(!empty);
      return result[count];
    }

    void popFront() {
      ++count;
    }

    uint numberOfColumns() {
      return ColumnsResultColumns.max;
    }
  }

private:
  IntegerColumnsResultRow[] result = [
    new IntegerColumnsResultRow("amount"),
    new IntegerColumnsResultRow("client")];
  int count = 0;
}

final class IntegerColumnsResultRow : OdbcResultRow {
  this(string columnName) {
    this.columnName = columnName;
  }
  Variant dataAt(int column) {
    with (ColumnsResultColumns) {
      switch (column) {
      case TABLE_CAT:
        return Variant("tpch");
      case TABLE_SCHEM:
        return Variant("tiny");
      case TABLE_NAME:
        return Variant("orders");
      case COLUMN_NAME:
        return Variant(columnName);
      case DATA_TYPE:
        return Variant(SQL_TYPE_ID.SQL_INTEGER);
      case TYPE_NAME:
        return Variant("INTEGER");
      case COLUMN_SIZE:
        return Variant(4 * 8);
      case BUFFER_LENGTH:
        return Variant(4);
      case DECIMAL_DIGITS:
        return Variant(0);
      case NUM_PREC_RADIX:
        return Variant(2);
      case NULLABLE:
        return Variant(Nullability.SQL_NO_NULLS);
      case REMARKS:
        return Variant("A faux column for testing");
      case COLUMN_DEF:
        return Variant("0");
      case SQL_DATA_TYPE:
        return Variant(SQL_TYPE_ID.SQL_INTEGER);
      case SQL_DATETIME_SUB:
        return Variant(null);
      case CHAR_OCTET_LENGTH:
        return Variant(null);
      case ORDINAL_POSITION:
        return Variant(1);
      case IS_NULLABLE:
        return Variant("NO");
      default:
        dllEnforce(false, "Non-existant column " ~ text(cast(ColumnsResultColumns) column));
        assert(false, "Silence compiler errors about not returning");
      }
    }
  }
private:
  string columnName;
}

enum ColumnsResultColumns {
  TABLE_CAT = 1,
  TABLE_SCHEM,
  TABLE_NAME,
  COLUMN_NAME,
  DATA_TYPE,
  TYPE_NAME,
  COLUMN_SIZE,
  BUFFER_LENGTH,
  DECIMAL_DIGITS,
  NUM_PREC_RADIX,
  NULLABLE,
  REMARKS,
  COLUMN_DEF,
  SQL_DATA_TYPE,
  SQL_DATETIME_SUB,
  CHAR_OCTET_LENGTH,
  ORDINAL_POSITION,
  IS_NULLABLE
}
