/*
 * type_input_fuzzer: the first input byte selects one of the built-in data types that parse
 * without catalog or locale state; the rest is the type's text representation, passed to its
 * input function.  A value that parses is rendered back with the type's output function.
 * Errors are handled with PG_TRY, as the backend itself does.
 */
#include "postgres.h"

#include "fmgr.h"
#include "miscadmin.h"
#include "tcop/tcopprot.h"
#include "utils/fmgrprotos.h"
#include "utils/memutils.h"

typedef struct TypeFuncs
{
	PGFunction	in;
	PGFunction	out;
} TypeFuncs;

static const TypeFuncs types[] = {
	{jsonb_in, jsonb_out},
	{json_in, json_out},
	{jsonpath_in, jsonpath_out},
	{numeric_in, numeric_out},
	{tsvectorin, tsvectorout},
	{tsqueryin, tsqueryout},
	{inet_in, inet_out},
	{cidr_in, cidr_out},
	{macaddr_in, macaddr_out},
	{macaddr8_in, macaddr8_out},
	{bit_in, bit_out},
	{varbit_in, varbit_out},
	{uuid_in, uuid_out},
	{box_in, box_out},
	{circle_in, circle_out},
	{line_in, line_out},
	{lseg_in, lseg_out},
	{path_in, path_out},
	{poly_in, poly_out},
	{point_in, point_out},
	{pg_lsn_in, pg_lsn_out},
	{float8in, float8out},
	{float4in, float4out},
	{int8in, int8out},
	{byteain, byteaout},
	{tidin, tidout},
	{xid8in, xid8out},
	{pg_snapshot_in, pg_snapshot_out},
};

int
LLVMFuzzerInitialize(int *argc, char ***argv)
{
	MemoryContextInit();
	whereToSendOutput = DestNone;
	Log_destination = 0;
	return 0;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	MemoryContext ctx;
	MemoryContext oldctx;
	volatile bool parsed = false;
	const TypeFuncs *t;
	char	   *text;

	if (size < 1)
		return -1;

	set_stack_base();

	t = &types[data[0] % lengthof(types)];

	ctx = AllocSetContextCreate(TopMemoryContext, "fuzz input", ALLOCSET_DEFAULT_SIZES);
	oldctx = MemoryContextSwitchTo(ctx);

	text = palloc(size);
	memcpy(text, data + 1, size - 1);
	text[size - 1] = '\0';

	PG_TRY();
	{
		Datum		d = DirectFunctionCall3(t->in, CStringGetDatum(text),
											ObjectIdGetDatum(InvalidOid), Int32GetDatum(-1));

		(void) DirectFunctionCall1(t->out, d);
		parsed = true;
	}
	PG_CATCH();
	{
		FlushErrorState();
	}
	PG_END_TRY();

	MemoryContextSwitchTo(oldctx);
	MemoryContextDelete(ctx);

	return parsed ? 0 : -1;
}
